
open Lwt.Infix
open Printf
open Util

module C = Cohttp
module Clwt = Cohttp_lwt
module Clu = Cohttp_lwt_unix

type accounts_templates_list_body = Accounts_templates_list_body_t.t
type accounts_templates_list_template = Accounts_templates_list_body_t.template
type videos_conversions_list_body = Videos_conversions_list_body_t.t
type videos_conversions_list_conversion
  = Videos_conversions_list_body_t.conversion
type videos_list_body = Videos_list_body_t.t
type videos_list_video = Videos_video_t.t
type videos_show_body = Videos_show_body_t.t

type param = string * string list

let api_prefix_url = "https://api.jwplatform.com/v1"

module type Config = sig
  val key : string
  val secret : string
end

module type Client = sig
  val call : string -> ?params : param list -> unit
             -> (C.Response.t * Clwt.Body.t) Lwt.t

  val accounts_templates_list : ?params : param list -> unit
                                    -> accounts_templates_list_body Lwt.t
  val videos_conversions_create : string -> string -> unit Lwt.t
  val videos_conversions_delete : string -> unit Lwt.t
  val videos_conversions_list : string -> videos_conversions_list_body Lwt.t
  val videos_list : ?params : param list -> unit -> videos_list_body Lwt.t
  val videos_show : string -> videos_show_body option Lwt.t
  val videos_update : string -> param list -> unit Lwt.t

  val create_conversion_by_name : string -> string -> unit Lwt.t
  val delete_conversion_by_name : string -> string -> unit Lwt.t
end


module Make (Conf : Config) : Client = struct

  (** [gen_required_params ()] generates the required parameters for an API
      call *)
  let gen_required_params () =
    let timestamp = Unix.time () |> int_of_float |> string_of_int in
    let nonce = Random.int @@ BatInt.pow 10 8 |> sprintf "%08d" in

    [ "api_format", ["json"];
      "api_key", [Conf.key];
      "api_timestamp", [timestamp];
      "api_nonce", [nonce] ]


  (** [sign_query params] generates a signatures based on the passed parameters
      and returns a new list of params with the signature *)
  let sign_query params =
    let query = params
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
      |> Uri.encoded_of_query 
      (* Catch extra characters expected to be encoded by JW *)
      |> BatString.replace_chars (function
        | ':' -> "%3A" 
        | c -> BatString.of_char c)
    in
    let signature = Sha1.(string (query ^ Conf.secret) |> to_hex) in
    ("api_signature", [signature]) :: params


  (** [call path ?params ()] Make a request to the endpoint at [path] with
      [params] as the query string. *)
  let rec call path ?(params=[]) () =
    let params' = merge_params (gen_required_params ()) params in
    let signed = sign_query params' in
    let query = Uri.encoded_of_query signed in
    let uri_str = [ api_prefix_url; path; "?"; query; ] |> String.concat "" in
    let uri = Uri.of_string uri_str in

    Clu.Client.get uri >>= fun (resp, body) ->

    let status = resp |> C.Response.status in
    let status_str = status |> C.Code.string_of_status in
    Lwt_io.printlf "[GOT %s]\n--> %s" uri_str status_str
      >>= fun () ->

    match status with
    | `Too_many_requests ->
      (* Wait and try again once the limit has reset *)
      let h = resp |> C.Response.headers in
      let reset =  match C.Header.get h "x-ratelimit-reset" with
        | None -> 60.
        | Some r -> match float_of_string_opt r with
          | None -> 60.
          | Some r -> BatFloat.max (r -. Unix.time ()) 1.
      in
      Lwt_io.printlf "--> Rate limit hit. Retrying in %f.1 second(s)..." reset
      >>= fun () ->
      Lwt_unix.sleep reset >>= fun () ->
      call path ~params ()
    | _ ->
      Lwt.return (resp, body)

  let accounts_templates_list ?params () =
    let%lwt (resp, body) = call "/accounts/templates/list" ?params () in
    begin match C.Response.status resp with
    | `OK -> Lwt.return ()
    |   s -> unexpected_response_status_exn resp body >>= raise
    end >>= fun () ->
    let%lwt body' = Clwt.Body.to_string body in
    Lwt.return @@ Accounts_templates_list_body_j.t_of_string body'

  (** [get_videos_list ?params ()] Makes a request to the [/videos/list] 
      endpoint and returns the parsed response. *)
  let videos_list ?params () =
    let%lwt (resp, body) = call "/videos/list" ?params () in
    match C.Response.status resp with
    | `OK ->
      let%lwt body' = Clwt.Body.to_string body in
      Lwt.return @@ Videos_list_body_j.t_of_string body'
    | s -> unexpected_response_status_exn resp body >>= raise

  let videos_show media_id =
    let%lwt (resp, body) =
      call "/videos/show" ~params:[("video_key", [media_id])] ()
    in
    match C.Response.status resp with
    | `Not_found -> Lwt.return None
    | `OK ->
      let%lwt body' = Clwt.Body.to_string body in
      Lwt.return @@ Some (Videos_show_body_j.t_of_string body')
    | s -> unexpected_response_status_exn resp body >>= raise

  let videos_update key params =
    let params' = merge_params [("video_key", [key])] params in
    let%lwt (resp, body) = call "/videos/update" ~params:params' () in

    match C.Response.status resp with
    | `OK -> Lwt.return ()
    | `Not_found -> raise Not_found
    |  s -> unexpected_response_status_exn resp body >>= raise

  let videos_conversions_create media_id template_key =
    let params = 
      [ ("video_key", [media_id])
      ; ("template_key", [template_key]) ]
    in
    let%lwt (resp, body) = call "/videos/conversions/create" ~params () in
    match C.Response.status resp with
    | `OK 
    | `Conflict (* already exists *) -> Lwt.return ()
    | `Not_found -> raise Not_found
    | s -> unexpected_response_status_exn resp body >>= raise

  let videos_conversions_list media_id =
    (* Leaving parameters `result_limit` and `result_offset` uncustomizable
     * as 1000 should way more than cover the possibilities for us at RTM. *)
    let params = [("video_key", [media_id]); ("result_limit", ["1000"])] in
    let%lwt (resp, body) = call "/videos/conversions/list" ~params () in
    match C.Response.status resp with
    | `OK ->
      let%lwt body' = Clwt.Body.to_string body in
      Lwt.return @@ Videos_conversions_list_body_j.t_of_string body'
    | `Not_found -> raise Not_found
    | s -> unexpected_response_status_exn resp body >>= raise

  let videos_conversions_delete key =
    let params = [("conversion_key", [key])] in
    let%lwt (resp, body) = call "/videos/conversions/delete" ~params () in
    match C.Response.status resp with
    | `OK -> Lwt.return ()
    | `Not_found -> raise Not_found
    | s -> unexpected_response_status_exn resp body >>= raise

  let create_conversion_by_name media_id template_name =
    let%lwt body = accounts_templates_list () in
    let name = String.lowercase_ascii template_name in
    let template = body.templates |> List.find begin fun t ->
      let open Accounts_templates_list_body_t in
      String.lowercase_ascii t.name = name
    end in
    videos_conversions_create media_id template.key
  
  let delete_conversion_by_name media_id template_name = 
    let%lwt body = videos_conversions_list media_id in
    let name = String.lowercase_ascii template_name in
    let conversion = body.conversions |> List.find begin fun c ->
      let open Videos_conversions_list_body_t in
      String.lowercase_ascii c.template.name = name
    end in
    videos_conversions_delete conversion.key

end
