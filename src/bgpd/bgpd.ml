open Lwt.Infix

(* Logging *)
let bgpd_src = Logs.Src.create "BGP" ~doc:"BGP logging"
module Bgp_log = (val Logs.src_log bgpd_src : Logs.LOG)

(* This is to simulate a cancellable lwt thread *)
module Device = struct
  type t = unit Lwt.t

  let create f callback : t =
    let t, u = Lwt.task () in
    let _ = 
      f () >>= fun x ->
      Lwt.wakeup u x;
      Lwt.return_unit
    in
    t >>= fun x ->
    (* To avoid callback being cancelled. *)
    let _ = callback x in
    Lwt.return_unit
  ;;

  let stop t = Lwt.cancel t
end

module  Main (S: Mirage_stack_lwt.V4) = struct
  type t = {
    conn_id: int;
    host_id: Ipaddr.V4.t;
    my_id: Ipaddr.V4.t;
    my_as: int;
    socket: S.t;
    mutable fsm: Fsm.t;
    mutable flow: S.TCPV4.flow option;
    mutable listen_tcp_conn: bool;
    mutable conn_retry_timer: Device.t option;
    mutable hold_timer: Device.t option;
    mutable keepalive_timer: Device.t option;
    mutable conn_starter: Device.t option;
    mutable tcp_flow_reader: Device.t option;
    mutable input_rib: Rib.Adj_rib.t option;
    mutable output_rib: Rib.Adj_rib.t option;
    mutable loc_rib: Rib.Loc_rib.t;
  }

  let create_timer time callback : Device.t =
    Device.create (fun () -> OS.Time.sleep_ns (Duration.of_sec time)) callback
  ;;

  let rec tcp_flow_reader t callback =
    (match t.conn_starter with
    | None -> ()
    | Some _ -> Bgp_log.warn (fun m -> m "new flow reader when there exists another conn starter."));

    match t.flow with
    | None -> Lwt.return_unit
    | Some flow -> begin
      let task () = S.TCPV4.read flow in

      let wrapped_callback result =
        match result with
        | Ok (`Data buf) -> begin
          match Bgp.parse_buffer_to_t buf with
          | Error err -> begin 
            (* TODO *)
            tcp_flow_reader t callback
          end
          | Ok msg ->
            let event = match msg with
            | Bgp.Open o -> Fsm.BGP_open o
            | Bgp.Update u -> Fsm.Update_msg u
            | Bgp.Notification e -> Fsm.Notif_msg e
            | Bgp.Keepalive -> Fsm.Keepalive_msg
            in
            (* Bgp_log.info (fun m -> m "receive message %s" (Bgp.to_string msg)); *)
            tcp_flow_reader t callback
            >>= fun () ->
            callback event
        end 
      | Error _ -> 
        Bgp_log.debug (fun m -> m "fail to read from TCP.");
        t.tcp_flow_reader <- None;
        callback Fsm.Tcp_connection_fail      
      | Ok (`Eof) -> 
        Bgp_log.debug (fun m -> m "TCP connection closed by remote.");
        t.tcp_flow_reader <- None;
        callback Fsm.Tcp_connection_fail
      in
      t.tcp_flow_reader <- Some (Device.create task wrapped_callback);
      Lwt.return_unit
    end
  ;;

  let init_tcp_connection t callback =
    (match t.conn_starter with
    | None -> ()
    | Some _ -> Bgp_log.warn (fun m -> m "new connection is initiated when there exists another conn starter."));

    match t.flow with
    | Some _ -> 
      Bgp_log.warn (fun m -> m "new connection is initiated when there exists an old connection.");
      Lwt.return_unit
    | None -> begin
      let task = fun () ->
        Bgp_log.debug (fun m -> m "try setting up TCP connection with remote peer.");
        S.TCPV4.create_connection (S.tcpv4 t.socket) (t.host_id, Key_gen.port ())
      in
      let wrapped_callback = function
        | Error _ -> 
          Bgp_log.debug (fun m -> m "fail to set up TCP connection.");
          t.conn_starter <- None;
          callback (Fsm.Tcp_connection_fail)
        | Ok flow -> begin
          match t.flow with
          | None ->
            Bgp_log.debug (fun m -> m "TCP connection succeeds.");
            t.flow <- Some flow;
            t.conn_starter <- None;
            tcp_flow_reader t callback
            >>= fun () ->
            callback Fsm.Tcp_CR_Acked
          | Some _ -> 
            Bgp_log.warn (fun m -> m "new connection is established when there exists an old connection. Discard new connection");
            t.conn_starter <- None;
            S.TCPV4.close flow
        end
      in
      t.conn_starter <- Some (Device.create task wrapped_callback);
      Lwt.return_unit
    end
  ;;      

  let listen_tcp_connection t callback =
    let on_connect = fun flow -> 
      if (t.listen_tcp_conn) then begin
        Bgp_log.debug (fun m -> m "accept incoming TCP connection from peer.");
        t.flow <- Some flow;
        tcp_flow_reader t callback
        >>= fun () ->
        callback Fsm.Tcp_connection_confirmed
      end
      else Lwt.return_unit (* Silently quit *)
    in
    S.listen_tcpv4 t.socket ~port:50001 on_connect
  ;;
                    
  let send_msg t msg = 
    match t.flow with
    | Some flow ->
      Bgp_log.info (fun m -> m "send message %s" (Bgp.to_string msg));
      S.TCPV4.write flow (Bgp.gen_msg msg) 
      >>= begin function
      | Error _ ->
        Bgp_log.debug (fun m -> m "fail to send TCP message %s" (Bgp.to_string msg));
        Lwt.return_unit
      | Ok () -> Lwt.return_unit
      end    
    | None -> Lwt.return_unit
  ;;

  let send_open_msg (t: t) =
    let open Bgp in
    let open Fsm in
    let o = {
      version = 4;
      bgp_id = Ipaddr.V4.to_int32 t.my_id;
      my_as = Asn t.my_as;
      hold_time = t.fsm.hold_time;
      options = [];
    } in
    send_msg t (Bgp.Open o) 
  ;;

  let drop_tcp_connection t =
    t.listen_tcp_conn <- false;
    
    (match t.conn_starter with
    | None -> ()
    | Some d -> 
      Bgp_log.debug (fun m -> m "close conn starter."); 
      t.conn_starter <- None;
      Device.stop d);

    (match t.tcp_flow_reader with
    | None -> ()
    | Some d -> 
      Bgp_log.debug (fun m -> m "close tcp flow reader."); 
      t.tcp_flow_reader <- None;
      Device.stop d);
    
    match t.flow with
    | None -> Lwt.return_unit
    | Some flow ->
      Bgp_log.debug (fun m -> m "close existing flow."); 
      t.flow <- None; 
      S.TCPV4.close flow;
  ;;

  let rec perform_action t action =
    let open Fsm in
    let callback = fun event -> handle_event t event in
    match action with
    | Initiate_tcp_connection -> init_tcp_connection t callback
    | Send_open_msg -> send_open_msg t
    | Send_msg msg -> send_msg t msg
    | Drop_tcp_connection -> drop_tcp_connection t
    | Listen_tcp_connection -> t.listen_tcp_conn <- true; Lwt.return_unit
    | Start_conn_retry_timer -> 
      if (t.fsm.conn_retry_time > 0) then begin
        let callback () =
          t.conn_retry_timer <- None;
          Bgp_log.info (fun m -> m "TCP connection timeouts.");
          handle_event t Connection_retry_timer_expired
        in
        t.conn_retry_timer <- Some (create_timer t.fsm.conn_retry_time callback);
      end;
      Lwt.return_unit
    | Stop_conn_retry_timer -> begin
      match t.conn_retry_timer with
      | None -> Lwt.return_unit
      | Some d -> t.conn_retry_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_conn_retry_timer -> begin
      (match t.conn_retry_timer with
      | None -> ()
      | Some t -> Device.stop t);
      if (t.fsm.conn_retry_time > 0) then begin
        let callback () =
          t.conn_retry_timer <- None;
          Bgp_log.info (fun m -> m "connection retry timer expired.");
          handle_event t Connection_retry_timer_expired
        in
        t.conn_retry_timer <- Some (create_timer t.fsm.conn_retry_time callback);
      end;
      Lwt.return_unit
    end
    | Start_hold_timer ht -> 
      if (t.fsm.hold_time > 0) then 
        t.hold_timer <- Some (create_timer ht (fun () -> t.hold_timer <- None; handle_event t Hold_timer_expired));
      Lwt.return_unit
    | Stop_hold_timer -> begin
      Bgp_log.info (fun m -> m "hold timer expires.");
      match t.hold_timer with
      | None -> Lwt.return_unit
      | Some d -> t.hold_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_hold_timer ht -> begin
      (match t.hold_timer with
      | None -> ()
      | Some d -> Device.stop d);
      if (t.fsm.hold_time > 0) then 
        t.hold_timer <- Some (create_timer ht (fun () -> t.hold_timer <- None; handle_event t Hold_timer_expired));
      Lwt.return_unit
    end
    | Start_keepalive_timer -> 
      if (t.fsm.keepalive_time > 0) then 
        t.keepalive_timer <- Some (create_timer t.fsm.keepalive_time 
                            (fun () -> t.keepalive_timer <- None; handle_event t Keepalive_timer_expired));
      Lwt.return_unit
    | Stop_keepalive_timer -> begin
      match t.keepalive_timer with
      | None -> Lwt.return_unit
      | Some d -> t.keepalive_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_keepalive_timer -> begin
      (match t.keepalive_timer with
      | None -> ()
      | Some t -> Device.stop t);
      if (t.fsm.keepalive_time > 0) then 
        t.keepalive_timer <- Some (create_timer t.fsm.keepalive_time 
                            (fun () -> t.keepalive_timer <- None; handle_event t Keepalive_timer_expired));
      Lwt.return_unit
    end
    | Process_update_msg u -> begin
      let converted = Util.Bgp_to_Rib.convert_update u in
      match t.input_rib with
      | None -> Lwt.fail_with "Input RIB not initiated."
      | Some rib -> Rib.Adj_rib.handle_update rib converted
    end
    | Initiate_rib ->
      let input_rib = 
        let callback u = Rib.Loc_rib.handle_signal t.loc_rib (Rib.Loc_rib.Update (u, t.conn_id)) in
        Rib.Adj_rib.create t.conn_id callback
      in
      t.input_rib <- Some input_rib;

      let output_rib =
        let callback u = 
          let converted = Util.Rib_to_Bgp.convert_update u in
          send_msg t (Bgp.Update converted)
        in
        Rib.Adj_rib.create t.conn_id callback
      in
      t.output_rib <- Some output_rib;

      Rib.Loc_rib.subscribe t.loc_rib output_rib
    | Release_rib ->
      t.input_rib <- None;
      match t.output_rib with
      | None -> Lwt.return_unit
      | Some rib -> t.output_rib <- None; Rib.Loc_rib.unsubscribe t.loc_rib rib
  
  and handle_event t event =
    Bgp_log.debug (fun m -> m "%s" (Fsm.event_to_string event));
    let new_fsm, actions = Fsm.handle t.fsm event in
    t.fsm <- new_fsm;
    (* Spawn threads to perform actions from left to right *)
    let _ = List.fold_left (fun acc act -> List.cons (perform_action t act) acc) [] actions in
    Lwt.return_unit
  ;;

  let start_bgp host_id my_id my_as socket =
    let fsm = Fsm.create 30 45 15 in
    let flow = None in
    let t = {
      conn_id = 0;
      host_id; my_id; my_as; 
      socket; fsm; flow;
      listen_tcp_conn = false; 
      conn_retry_timer = None; 
      hold_timer = None; 
      keepalive_timer = None;
      conn_starter = None;
      tcp_flow_reader = None;
      input_rib = None;
      output_rib = None;
      loc_rib = Rib.Loc_rib.create;
    } in

    (* Start listening to BGP port. *)
    listen_tcp_connection t (handle_event t);

    (* This is the command loop *)
    let rec loop () =
      Lwt_io.read_line Lwt_io.stdin
      >>= function
      | "start" -> 
        Bgp_log.info (fun m -> m "BGP starts.");
        handle_event t (Fsm.Manual_start) >>= loop
      | "stop" -> 
        Bgp_log.info (fun m -> m "BGP stops.");
        handle_event t (Fsm.Manual_stop) >>= loop
      | "exit" -> 
        handle_event t (Fsm.Manual_stop)
        >>= fun () ->
        Bgp_log.info (fun m -> m "BGP exits.");
        S.disconnect socket
        >>= fun () ->
        Lwt.return_unit
      | "show fsm" ->
        Bgp_log.info (fun m -> m "status: %s" (Fsm.to_string t.fsm));
        loop ()
      | "show device" ->
        let dev1 = if not (t.conn_retry_timer = None) then "Conn retry timer" else "" in
        let dev2 = if not (t.hold_timer = None) then "Hold timer" else "" in 
        let dev3 = if not (t.keepalive_timer = None) then "Keepalive timer" else "" in 
        let dev4 = if not (t.conn_starter = None) then "Conn starter" else "" in 
        let dev5 = if not (t.tcp_flow_reader = None) then "Flow reader" else "" in 
        let dev6 = if (t.listen_tcp_conn) then "Listen tcp conneciton." else "" in 
        let str_list = List.filter (fun x -> not (x = "")) ["Running device:"; dev1; dev2; dev3; dev4; dev5; dev6] in
        Bgp_log.info (fun m -> m "%s" (String.concat "\n" str_list));
        loop ()
      | "show rib" ->
        (match t.input_rib with
        | None -> Bgp_log.warn (fun m -> m "No IN RIB.");
        | Some rib -> Bgp_log.info (fun m -> m "Adj_RIB_IN \n %s" (Rib.Adj_rib.to_string rib)));

        Bgp_log.info (fun m -> m "%s" (Rib.Loc_rib.to_string t.loc_rib));

        (match t.output_rib with
        | None -> Bgp_log.warn (fun m -> m "No OUT RIB.");
        | Some rib -> Bgp_log.info (fun m -> m "Adj_RIB_OUT \n %s" (Rib.Adj_rib.to_string rib)));
        
        loop ()
      | _ -> Lwt.return_unit >>= loop
    in
    loop ()
  ;;

  let start s =
    let host = Ipaddr.V4.of_string_exn (Key_gen.host ()) in
    let id = Ipaddr.V4.of_string_exn (Key_gen.id ()) in
    let my_as = Key_gen.asn () in  
    start_bgp host id my_as s
  ;;


end