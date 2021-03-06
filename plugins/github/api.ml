open Lwt.Infix
open Current.Syntax

(* Currently, this fires whenever we get an incoming web-hook.
   Ideally, it would be more fine-grained. *)
let webhook_cond = Lwt_condition.create ()

let input_webhook () = Lwt_condition.broadcast webhook_cond ()

module Metrics = struct
  open Prometheus

  let namespace = "ocurrent"
  let subsystem = "github"

  let remaining_points =
    let help = "Points remaining at time of last query" in
    Gauge.v_label ~label_name:"account" ~help ~namespace ~subsystem "remaining_points"

  let used_points_total =
    let help = "Total GraphQL query points used" in
    Counter.v_label ~label_name:"account" ~help ~namespace ~subsystem "used_points_total"
end

let graphql_endpoint = Uri.of_string "https://api.github.com/graphql"

let status_endpoint ~owner_name ~commit =
  Uri.of_string (Fmt.strf "https://api.github.com/repos/%s/statuses/%s"
                   owner_name commit)

let read_file path =
  let ch = open_in_bin path in
  Fun.protect
    (fun () ->
       let len = in_channel_length ch in
       really_input_string ch len
    )
    ~finally:(fun () -> close_in ch)

module Repo_map = Map.Make(Repo_id)

module Status = struct
  type state = [`Error | `Failure | `Pending | `Success ]

  type t = {
    state : state;
    description : string option;
    url : Uri.t option;
  }

  let v ?description ?url state =
    let description = Option.map (Astring.String.with_range ~len:140) description in (* Max GitHub allows *)
    { state; description; url }

  let state_to_string = function
    | `Error   -> "error"
    | `Failure -> "failure"
    | `Pending -> "pending"
    | `Success -> "success"

  let json_items { state; description; url } =
    ["state", `String (state_to_string state)] @
    (match description with None -> [] | Some x -> ["description", `String x]) @
    (match url with None -> [] | Some x -> ["target_url", `String (Uri.to_string x)])

  let digest t = Yojson.Safe.to_string @@ `Assoc (json_items t)

  let pp f t = Fmt.string f (digest t)
end

type token = {
  token : (string, [`Msg of string]) result;
  expiry : float option;
}

let no_token = {
  token = Error (`Msg "Not fetched yet");
  expiry = Some (-1.0);
}

module Commit_id = struct
  type t = {
    owner_name : string;    (* e.g. "owner/name" *)
    id : [ `Ref of string | `PR of int ];
    hash : string;
  } [@@deriving to_yojson]

  let to_git { owner_name; id; hash } =
    let repo = Fmt.strf "https://github.com/%s.git" owner_name in
    let gref =
      match id with
      | `Ref head -> head
      | `PR id -> Fmt.strf "refs/pull/%d/head" id
    in
    Current_git.Commit_id.v ~repo ~gref ~hash

  let pp_id f = function
    | `Ref r -> Fmt.string f r
    | `PR pr -> Fmt.pf f "PR %d" pr

  let pp f { owner_name; id; hash } =
    Fmt.pf f "@[<v>%s@,%a@,%s@]" owner_name pp_id id (Astring.String.with_range ~len:8 hash)

  let digest t = Yojson.Safe.to_string (to_yojson t)
end

type t = {
  account : string;          (* Prometheus label used to report points. *)
  get_token : unit -> token Lwt.t;
  token_lock : Lwt_mutex.t;
  mutable token : token;
  mutable head_inputs : commit Current.Input.t Repo_map.t;
  mutable ci_refs_inputs : ci_refs Current.Input.t Repo_map.t;
}
and commit = t * Commit_id.t
and ci_refs = commit list

let v ~get_token account =
  let head_inputs = Repo_map.empty in
  let ci_refs_inputs = Repo_map.empty in
  let token_lock = Lwt_mutex.create () in
  { get_token; token_lock; token = no_token; head_inputs; ci_refs_inputs; account }

let of_oauth token =
  let get_token () = Lwt.return { token = Ok token; expiry = None } in
  v ~get_token "oauth"

let get_token t =
  Lwt_mutex.with_lock t.token_lock @@ fun () ->
  let now = Unix.gettimeofday () in
  match t.token with
  | { token; expiry = None } -> Lwt.return token
  | { token; expiry = Some expiry } when now < expiry -> Lwt.return token
  | _ ->
    Log.info (fun f -> f "Getting API token");
    Lwt.catch t.get_token
      (fun ex ->
         Log.warn (fun f -> f "Error getting GitHub token: %a" Fmt.exn ex);
         let token = Error (`Msg "Failed to get GitHub token") in
         let expiry = Some (now +. 60.0) in
         Lwt.return {token; expiry}
      )
    >|= fun token ->
    t.token <- token;
    token.token

let ( / ) a b = Yojson.Safe.Util.member b a

let exec_graphql ?variables t query =
  let body =
    `Assoc (
      ("query", `String query) ::
      (match variables with
       | None -> []
       | Some v -> ["variables", `Assoc v])
    )
    |> Yojson.Safe.to_string
    |> Cohttp_lwt.Body.of_string
  in
  get_token t >>= function
  | Error (`Msg m) -> Lwt.fail_with m
  | Ok token ->
    let headers = Cohttp.Header.init_with "Authorization" ("bearer " ^ token) in
    Cohttp_lwt_unix.Client.post ~headers ~body graphql_endpoint >>=
    fun (resp, body) ->
    Cohttp_lwt.Body.to_string body >|= fun body ->
    match Cohttp.Response.status resp with
    | `OK ->
      let json = Yojson.Safe.from_string body in
      let open Yojson.Safe.Util in
      begin match json / "errors" with
        | `Null -> json
        | errors ->
          Log.warn (fun f -> f "@[<v2>GitHub returned errors: %a@]" (Yojson.Safe.pretty_print ~std:true) json);
          match errors with
          | `List (error :: _) ->
            let msg = error / "message" |> to_string in
            Fmt.failwith "Error from GitHub GraphQL: %s" msg;
          | _ ->
            Fmt.failwith "Unknown error type from GitHub GraphQL"
      end
    | err -> Fmt.failwith "@[<v2>Error performing GraphQL query on GitHub: %s@,%s@]"
               (Cohttp.Code.string_of_status err)
               body

let query_default =
  "query($owner: String!, $name: String!) { \
   rateLimit { \
     cost \
     remaining \
     resetAt \
   } \
   repository(owner: $owner, name: $name) { \
     nameWithOwner \n
     defaultBranchRef { \
       prefix \
       name \
       target { \
         oid \
       } \
     } \
   } \
 }"

let handle_rate_limit t name json =
  let open Yojson.Safe.Util in
  let cost = json / "cost" |> to_int in
  let remaining = json / "remaining" |> to_int in
  let reset_at = json / "resetAt" |> to_string in
  Log.info (fun f -> f "GraphQL(%s): cost:%d remaining:%d resetAt:%s" name cost remaining reset_at);
  Prometheus.Counter.inc (Metrics.used_points_total t.account) (float_of_int cost);
  Prometheus.Gauge.set (Metrics.remaining_points t.account) (float_of_int remaining)

let default_ref t { Repo_id.owner; name } =
    let variables = [
      "owner", `String owner;
      "name", `String name;
    ] in
    exec_graphql t ~variables query_default >|= fun json ->
    try
      let open Yojson.Safe.Util in
      let data = json / "data" in
      handle_rate_limit t "default_ref" (data / "rateLimit");
      let repo = data / "repository" in
      let owner_name = repo / "nameWithOwner" |> to_string in
      let def = repo / "defaultBranchRef" in
      let prefix = def / "prefix" |> to_string in
      let name = def / "name" |> to_string in
      let hash = def / "target" / "oid" |> to_string in
      { Commit_id.owner_name; id = `Ref (prefix ^ name); hash }
    with ex ->
      let pp f j = Yojson.Safe.pretty_print f j in
      Log.err (fun f -> f "@[<v2>Invalid JSON: %a@,%a@]" Fmt.exn ex pp json);
      raise ex

let make_head_commit_input t repo =
  let read () =
    Lwt.catch
      (fun () -> default_ref t repo >|= fun c -> Ok (t, c))
      (fun ex -> Lwt_result.fail @@ `Msg (Fmt.strf "GitHub query for %a failed: %a" Repo_id.pp repo Fmt.exn ex))
  in
  let watch refresh =
    let rec aux x =
      x >>= fun () ->
      let x = Lwt_condition.wait webhook_cond in
      refresh ();
      Lwt_unix.sleep 10.0 >>= fun () ->   (* Limit updates to 1 per 10 seconds *)
      aux x
    in
    let x = Lwt_condition.wait webhook_cond in
    let thread =
      Lwt.catch
        (fun () -> aux x)
        (function
          | Lwt.Canceled -> Lwt.return_unit
          | ex -> Log.err (fun f -> f "head_commit thread failed: %a" Fmt.exn ex); Lwt.return_unit
        )
    in
    Lwt.return (fun () -> Lwt.cancel thread; Lwt.return_unit)
  in
  let pp f = Fmt.pf f "Watch %a default ref head" Repo_id.pp repo in
  Current.monitor ~read ~watch ~pp

let head_commit t repo =
  Current.component "%a head" Repo_id.pp repo |>
  let> () = Current.return () in
  match Repo_map.find_opt repo t.head_inputs with
  | Some i -> i
  | None ->
    let i = make_head_commit_input t repo in
    t.head_inputs <- Repo_map.add repo i t.head_inputs;
    i

let head_commit_dyn t repo =
  Current.component "head" |>
  let> t = t
  and> repo = repo in
  match Repo_map.find_opt repo t.head_inputs with
  | Some i -> i
  | None ->
    let i = make_head_commit_input t repo in
    t.head_inputs <- Repo_map.add repo i t.head_inputs;
    i

let query_branches_and_open_prs = {|
  query($owner: String!, $name: String!) {
    rateLimit {
      cost
      remaining
      resetAt
    }
    repository(owner: $owner, name: $name) {
      nameWithOwner
      refs(first: 100, refPrefix:"refs/heads/") {
        totalCount
        edges {
          node {
            name
            target {
              oid
            }
          }
        }
      }
      pullRequests(first: 100, states:[OPEN]) {
        totalCount
        edges {
          node {
            number
            headRefOid
          }
        }
      }
    }
  }
|}

let parse_ref ~owner_name ~prefix json =
  let open Yojson.Safe.Util in
  let node = json / "node" in
  let name = node / "name" |> to_string in
  let hash = node / "target" / "oid" |> to_string in
  { Commit_id.owner_name; id = `Ref (prefix ^ name); hash }

let parse_pr ~owner_name json =
  let open Yojson.Safe.Util in
  let node = json / "node" in
  let hash = node / "headRefOid" |> to_string in
  let pr = node / "number" |> to_int in
  { Commit_id.owner_name; id = `PR pr; hash }

let get_ci_refs t { Repo_id.owner; name } =
    let variables = [
      "owner", `String owner;
      "name", `String name;
    ] in
    exec_graphql t ~variables query_branches_and_open_prs >|= fun json ->
    try
      let open Yojson.Safe.Util in
      let data = json / "data" in
      handle_rate_limit t "default_ref" (data / "rateLimit");
      let repo = data / "repository" in
      let owner_name = repo / "nameWithOwner" |> to_string in
      let refs =
        repo / "refs" / "edges" |> to_list |> List.map (parse_ref ~owner_name ~prefix:"refs/heads/")
        |> List.map (fun r -> (t, r)) in
      let prs =
        repo / "pullRequests" / "edges" |> to_list |> List.map (parse_pr ~owner_name)
        |> List.map (fun r -> (t, r)) in
      (* TODO: use cursors to get all results.
         For now, we just take the first 100 and warn if there are more. *)
      let n_branches = repo / "refs" / "totalCount" |> to_int in
      let n_prs = repo / "pullRequests" / "totalCount" |> to_int in
      if List.length refs < n_branches then
        Log.warn (fun f -> f "Too many branches in %s/%s (%d)" owner name n_branches);
      if List.length prs < n_prs then
        Log.warn (fun f -> f "Too many open PRs in %s/%s (%d)" owner name n_prs);
      let refs = refs |> List.filter (fun (_, c) -> c.Commit_id.id <> `Ref "refs/heads/gh-pages") in
      refs @ prs
    with ex ->
      let pp f j = Yojson.Safe.pretty_print f j in
      Log.err (fun f -> f "@[<v2>Invalid JSON: %a@,%a@]" Fmt.exn ex pp json);
      raise ex

let make_ci_refs_input t repo =
  let read () =
    Lwt.catch
      (fun () -> get_ci_refs t repo >|= Stdlib.Result.ok)
      (fun ex -> Lwt_result.fail @@ `Msg (Fmt.strf "GitHub query for %a failed: %a" Repo_id.pp repo Fmt.exn ex))
  in
  let watch refresh =
    let rec aux x =
      x >>= fun () ->
      let x = Lwt_condition.wait webhook_cond in
      refresh ();
      Lwt_unix.sleep 10.0 >>= fun () ->   (* Limit updates to 1 per 10 seconds *)
      aux x
    in
    let x = Lwt_condition.wait webhook_cond in
    let thread =
      Lwt.catch
        (fun () -> aux x)
        (function
          | Lwt.Canceled -> Lwt.return_unit
          | ex -> Log.err (fun f -> f "ci_refs thread failed: %a" Fmt.exn ex); Lwt.return_unit
        )
    in
    Lwt.return (fun () -> Lwt.cancel thread; Lwt.return_unit)
  in
  let pp f = Fmt.pf f "Watch %a CI refs" Repo_id.pp repo in
  Current.monitor ~read ~watch ~pp

let ci_refs t repo =
  Current.component "%a CI refs" Repo_id.pp repo |>
  let> () = Current.return () in
  match Repo_map.find_opt repo t.ci_refs_inputs with
  | Some i -> i
  | None ->
    let i = make_ci_refs_input t repo in
    t.ci_refs_inputs <- Repo_map.add repo i t.ci_refs_inputs;
    i

let ci_refs_dyn t repo =
  Current.component "CI refs" |>
  let> t = t
  and> repo = repo in
  match Repo_map.find_opt repo t.ci_refs_inputs with
  | Some i -> i
  | None ->
    let i = make_ci_refs_input t repo in
    t.ci_refs_inputs <- Repo_map.add repo i t.ci_refs_inputs;
    i

module Commit = struct
  module Set_status = struct
    let id = "github-set-status"

    type nonrec t = t

    module Key = struct
      type t = {
        commit : Commit_id.t;
        context : string;
      }

      let to_json { commit; context } =
        `Assoc [
          "commit", `String (Commit_id.digest commit);
          "context", `String context
        ]

      let digest t = Yojson.Safe.to_string (to_json t)
    end

    module Value = Status

    module Outcome = Current.Unit

    let auto_cancel = false

    let pp f ({ Key.commit; context }, status) =
      Fmt.pf f "Set %a/%s to %a"
        Commit_id.pp commit
        context
        Value.pp status

    let publish ~switch:_ t job key status =
      Current.Job.start job ~level:Current.Level.Above_average >>= fun () ->
      let {Key.commit; context} = key in
      let body = `Assoc (("context", `String context) :: Value.json_items status) in
      get_token t >>= function
      | Error (`Msg m) -> Lwt.fail_with m
      | Ok token ->
        let headers = Cohttp.Header.init_with "Authorization" ("bearer " ^ token) in
        let uri = status_endpoint
            ~owner_name:commit.Commit_id.owner_name
            ~commit:commit.Commit_id.hash
        in
        Current.Job.log job "@[<v2>POST %a:@,%a@]"
          Uri.pp uri
          (Yojson.Safe.pretty_print ~std:true) body;
        let body = body |> Yojson.Safe.to_string |> Cohttp_lwt.Body.of_string in
        Cohttp_lwt_unix.Client.post ~headers ~body uri >>= fun (resp, body) ->
        Cohttp_lwt.Body.to_string body >|= fun body ->
        match Cohttp.Response.status resp with
        | `Created -> Ok ()
        | err ->
          Log.warn (fun f -> f "@[<v2>%a failed: %s@,%s@]"
                       pp (key, status)
                       (Cohttp.Code.string_of_status err)
                       body);
          Error (`Msg "Failed to set GitHub status")
  end

  module Set_status_cache = Current_cache.Output(Set_status)

  type t = commit

  let id (_, commit_id) = Commit_id.to_git commit_id

  let owner_name (_, id) = id.Commit_id.owner_name

  let hash (_, id) = id.Commit_id.hash

  let pp = Fmt.using snd Commit_id.pp

  let set_status commit context status =
    Current.component "set_status" |>
    let> (t, commit) = commit
    and> status = status in
    Set_status_cache.set t {Set_status.Key.commit; context} status
end

open Cmdliner

let token_file =
  Arg.required @@
  Arg.opt Arg.(some file) None @@
  Arg.info
    ~doc:"A file containing the GitHub OAuth token."
    ~docv:"PATH"
    ["github-token-file"]

let make_config token_file =
  of_oauth @@ (String.trim (read_file token_file))

let cmdliner =
  Term.(const make_config $ token_file)
