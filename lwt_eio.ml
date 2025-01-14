open Eio.Std

exception Cancel

let ignore_cancel = function
  | Cancel -> ()
  | ex -> raise ex

(* Call this to cause the current [Lwt_engine.iter] to return. *)
let ready = ref (lazy ())

(* While the Lwt event loop is running, this is the switch that contains any fibres handling Lwt operations.
   Lwt does not use structured concurrency, so it can spawn background threads without explicitly taking a
   switch argument, which is why we need to use a global variable here. *)
let loop_switch = ref None

let notify () = Lazy.force !ready

(* Run [fn] in a new fibre and return a lazy value that can be forced to cancel it. *)
let fork_with_cancel ~sw fn =
  let cancel = ref None in
  Fibre.fork_sub ~sw ~on_error:ignore_cancel (fun sw ->
      cancel := Some (lazy (Switch.turn_off sw Cancel));
      fn ()
    );
  (* The forked fibre runs first, so [cancel] must be set by now. *)
  Option.get !cancel

let make_engine ~sw ~clock = object
  inherit Lwt_engine.abstract

  method private cleanup = Switch.turn_off sw Exit

  method private register_readable fd callback =
    let fd = Eio_linux.FD.of_unix ~sw ~seekable:false fd in
    fork_with_cancel ~sw @@ fun () ->
    Ctf.label "await_readable";
    while true do
      Eio_linux.await_readable fd;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    done

  method private register_writable fd callback =
    let fd = Eio_linux.FD.of_unix ~sw ~seekable:false fd in
    fork_with_cancel ~sw @@ fun () ->
    Ctf.label "await_writable";
    while true do
      Eio_linux.await_writable fd;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    done

  method private register_timer delay repeat callback =
    fork_with_cancel ~sw @@ fun () ->
    Ctf.label "await timer";
    if repeat then (
      while true do
        Eio.Time.sleep clock delay;
        Eio.Cancel.protect (fun () -> callback (); notify ())
      done
    ) else (
      Eio.Time.sleep clock delay;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    )

  method iter block =
    if block then (
      let p, r = Promise.create () in
      ready := lazy (Promise.fulfill r ());
      Promise.await p
    ) else (
      Fibre.yield ()
    )
end

type no_return = |

(* Run an Lwt event loop until [user_promise] resolves. Raises [Exit] when done. *)
let main ~clock user_promise : no_return =
  Switch.run @@ fun sw ->
  if Option.is_some !loop_switch then invalid_arg "Lwt_eio event loop already running";
  Switch.on_release sw (fun () -> loop_switch := None);
  loop_switch := Some sw;
  Lwt_engine.set (make_engine ~sw ~clock);
  (* An Eio fibre may resume an Lwt thread while in [Lwt_engine.iter] and forget to call [notify].
     If that called [Lwt.pause] then it wouldn't wake up, so handle this common case here. *)
  Lwt.register_pause_notifier (fun _ -> notify ());
  Lwt_main.run user_promise;
  (* Stop any event fibres still running: *)
  raise Exit

let with_event_loop ~clock fn =
  let p, r = Lwt.wait () in
  Switch.run @@ fun sw ->
  Fibre.fork ~sw (fun () ->
      match main ~clock p with
      | _ -> .
      | exception Exit -> ()
    );
  Fun.protect fn
    ~finally:(fun () ->
      Lwt.wakeup r ();
      notify ()
    )

let get_loop_switch () =
  match !loop_switch with
  | Some sw -> sw
  | None -> Fmt.failwith "Must be called from within Lwt_eio.with_event_loop!"

module Promise = struct
  let await_lwt lwt_promise =
    let p, r = Promise.create () in
    Lwt.on_any lwt_promise (Promise.fulfill r) (Promise.break r);
    Promise.await p

  let await_eio eio_promise =
    let sw = get_loop_switch () in
    let p, r = Lwt.wait () in
    Fibre.fork ~sw (fun () ->
        match Promise.await_result eio_promise with
        | Ok x -> Lwt.wakeup r x; notify ()
        | Error ex -> Lwt.wakeup_exn r ex; notify ()
      );
    p
end
