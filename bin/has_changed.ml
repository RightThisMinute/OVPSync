
module Blist = BatList
module Bopt = BatOption


let plf fmt = Printf.ksprintf (print_endline) fmt


let check debug media_id name changed =
  if debug && changed 
    then plf "### [%s] %s: changed ###" media_id name else ();
  changed


let rec items_are_same la lb =
  if List.compare_lengths la lb <> 0 then false
  else

  match la with
  | [] -> Blist.is_empty lb
  | hd :: tl ->
    let filter = List.filter ((<>) hd) in
    items_are_same (filter tl) (filter lb)


let sources_are_same = Rdb_dest.Source.are_same
let source = Rdb_dest.Source.has_changed

let sources_have_changed old knew =
  knew |> List.exists begin fun k ->
    match List.find_opt (sources_are_same k) old with
    | None -> true
    | Some o -> source o k
  end


let local_scheme = function
  | None -> false
  | Some u -> Uri.scheme u = Some Rdb_dest.local_scheme


let video ?(debug=false) ~check_md5 old knew =
  let open Rdb_dest.Video in
  let chk = check debug old.canonical.media_id in

  (* At first I tried just comparing update/modified timestamps and the MD5
     of the video file, but because the source may do clean up on the item
     after giving it to the destination, these timestamps are likely to change. 
     *)
     chk "title" (old.title <>knew.title)
  || chk "slug" (old.slug <> knew.slug)
  || chk "publish" (old.publish <> knew.publish)
  || chk "expires" (old.expires <> knew.expires)

  (* file_uri and thumbnail_uri are not compared if the old URIs are local. If
     they're not local, it implies that either no URI was provided before or
     there was a failure to save the file in the previous attempt. *)
  || chk "thumbnail_uri" begin 
       not (local_scheme old.thumbnail_uri) 
       (* File was not saved previously, unless URI was always [None],
          this needs another attempt at syncing. *)
       && not (old.thumbnail_uri = None && knew.thumbnail_uri = None)
     end
  || chk "file_uri" begin
       not (local_scheme old.file_uri) 
       (* File was not saved previously, unless URI was always [None],
           this needs another attempt at syncing. *)
         && not (old.file_uri = None && knew.file_uri = None)
     end

  (* filename is not checked, as the name stored in the database is based on
     the name of the file saved. This may have extra data attached and may not
     be taken exactly from what is passed from the source. *)

  (* MD5 may not want to be checked if it's not based on the file. For example,
     with JW, videos can just be URLs to a video file. In that case, the MD5
     is generated from the URL of the file, not the file itself and will
     always be different from the MD5 generated by this destination. *)
  || check_md5 && chk "md5" (old.md5 <> knew.md5)

  (* width & height are not checked. Some OVPs don't make the original video
     file available by default, requiring changes to be applied to the asset
     before it can be accessed (JW is like this). This includes information
     about its width and height. We don't want to require that when checking
     if it has changed. The MD5 would change if the width and height had
     changed anyway. *)

  || chk "duration" (old.duration <> knew.duration)
  || chk "description" (old.description <> knew.description)
  || chk "tags" (not (items_are_same old.tags knew.tags))
  || chk "cms_id" (old.cms_id <> knew.cms_id)
  || chk "link" (old.link <> knew.link)
  || chk "custom" (not (items_are_same old.custom knew.custom))
  || chk "source" (not (sources_are_same old.canonical knew.canonical))
  || chk "canonical" (source old.canonical knew.canonical)
  || chk "sources" (sources_have_changed old.sources knew.sources)
