open Lwt.Infix

(* Design choices: Use signal-and-continue *)

(* Logging *)
let ctl_src = Logs.Src.create "Ctl" ~doc:"CTL logging"
module Ctl_log = (val Logs.src_log ctl_src : Logs.LOG)

module Id_map = Map.Make(Ipaddr.V4)
module Str_map = Map.Make(String)

module  Main (C: Mirage_console_lwt.S) (S: Mirage_stack_lwt.V4) = struct
  module Router = Router.Make(S)
  open Router

  let rec command_loop console peers loc_rib =
    C.read console >>= function
    | Error err -> 
      Ctl_log.warn (fun m -> m "Fail to read command: %a" C.pp_error err);
      Lwt.return_unit
    | Ok (`Eof) ->
      Ctl_log.warn (fun m -> m "Console closed?");
      Lwt.return_unit
    | Ok (`Data b) ->
      match String.trim @@ Cstruct.to_string b with
      | "start" -> 
        let f peer =
          Ctl_log.info (fun m -> m "BGP peer %s starts." (Ipaddr.V4.to_string peer.remote_id));
          push_event peer (Fsm.Manual_start)
        in
        let _ = Id_map.map f peers in
        command_loop console peers loc_rib
      | "stop" -> 
        let f peer =
          Ctl_log.info (fun m -> m "BGP peer %s stops." (Ipaddr.V4.to_string peer.remote_id));
          push_event peer (Fsm.Manual_stop)
        in
        let _ = Id_map.map f peers in
        command_loop console peers loc_rib
      | "show peers" ->
        let f peer = 
          Ctl_log.info (fun m -> m "%s" (Router.router_to_string peer))
        in
        let _ = Id_map.map f peers in
        command_loop console peers loc_rib
      | "show routes" ->
        let () = 
          if Rib.Loc_rib.size loc_rib = 0 then 
            Ctl_log.info (fun m -> m "Empty Loc Rib.")
          else 
            Ctl_log.info (fun m -> m "Routes:\n%s" (Rib.Loc_rib.to_string loc_rib))
        in
        command_loop console peers loc_rib
      | "show gc" ->
        let word_to_KB ws = ws * 8 / 1024 in

        let gc_stat = Gc.stat () in
        let open Gc in
        let allocation = Printf.sprintf "Minor: %.0f, Promoted: %.0f, Major %.0f" 
                                gc_stat.minor_words gc_stat.promoted_words gc_stat.major_words in
        let size = Printf.sprintf "Heap size: %d KB, Stack size: %d KB" 
                                (word_to_KB gc_stat.heap_words) (word_to_KB gc_stat.stack_size) in
        let collection = Printf.sprintf "Minor collection: %d, Major collection: %d, Compaction: %d" 
                                gc_stat.minor_collections gc_stat.major_collections gc_stat.compactions in
        Ctl_log.info (fun m -> m "%s" (String.concat "\n" ["GC stat:"; allocation; size; collection]));
        
        command_loop console peers loc_rib
      | "exit" ->
        Lwt.return_unit
      | str -> 
        Ctl_log.info (fun m -> m "Unrecognised command %s" str);
        command_loop console peers loc_rib
  ;;

  (* let parse_config kv =
    let key = Key_gen.config () in
    KV.size kv key >>= function
    | Error e -> 
      Ctl_log.err (fun f -> f "Could not read config file: %a" KV.pp_error e);
      Lwt.return Config_parser.default_config
    | Ok size -> 
      KV.read kv key 0L size >>= function
      | Error e ->
        Ctl_log.err (fun f -> f "Could not read config file: %a" KV.pp_error e);
        Lwt.return Config_parser.default_config
      | Ok data ->
        let str = String.concat "" @@ List.map (fun b -> Cstruct.to_string b) data in     
        Lwt.return @@ Config_parser.parse_from_string str
  ;; *)

  
  let gc_major_count = ref 0

  let start console s =
    (* let () = if Key_gen.gc () then 
      let open Gc in

      let r = Gc.get () in
      r.minor_heap_size 

      let _ = Gc.create_alarm 
            (fun () -> 
              let tmp = Gc.quick_stat () in
              
              let minor = tmp.minor_collections in
              let major = tmp.major_collections in
              let compactions = tmp.compactions in

              Logs.info (fun m -> m "Major GC %d, Minor GC %d, Compaction %d" major minor compactions)
            ) 
      in
      ()
    else ()
    in *)

    let open Config_parser in

    (* Record backtrace *)
    Printexc.record_backtrace true;

    (* Parse config from file *)
    (* parse_config kv >>= fun config -> *)
    let config = parse_from_file (Key_gen.config ()) in

    let route_mgr = Route_mgr.create () in

    (* Init loc-rib *)
    let loc_rib = Rib.Loc_rib.create config.local_id config.local_asn route_mgr in

    (* Init out rib *)
    let rec init_out_rib acc peer = 
      match peer.peer_group with
      | None -> acc
      | Some out_rib_id ->
        match List.assoc_opt out_rib_id acc with
        | None -> 
          let out_rib = Rib.Adj_rib_out.create 
                                    out_rib_id 
                                    config.local_id config.local_asn 
                                    (config.local_asn = peer.remote_asn) 
                                    true None true
          in
          (out_rib_id, out_rib)::acc
        | Some _ -> acc
    in
    let out_rib_registry = List.fold_left init_out_rib [] config.peers in

    (* Init Routers *)
    let init_router acc peer =
      let router = Router.create s loc_rib out_rib_registry config peer in
      Id_map.add router.remote_id router acc
    in
    let peers = List.fold_left init_router (Id_map.empty) config.peers in

    (* Start listening to BGP port. *)
    let local_port = config.local_port in
    Router.listen_tcp_connection s local_port peers;
    
    (* Automatic passive start *)
    let f _id (peer: Router.t) =
      Ctl_log.info (fun m -> m "BGP peer %s autostarts." (Ipaddr.V4.to_string peer.remote_id));
      push_event peer Fsm.Automatic_start_passive_tcp
    in
    let () = Id_map.iter f peers in

    (* For test *)
    (if Key_gen.test () then 
      OS.Time.sleep_ns (Duration.of_sec (Key_gen.runtime ()))
    else 
      command_loop console peers loc_rib
    )
    >>= fun () ->

    (* Clean up *)
    let f _id (peer: Router.t) = Router.stop peer in
    let () = Id_map.iter f peers in
    S.disconnect s
  ;;
end
