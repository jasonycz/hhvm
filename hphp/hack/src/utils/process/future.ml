(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(**
 * We shell out hg commands, so its computation is out-of-process, and
 * return a Future for the result.
 *
 * A promise is a strongly-typed wrapper around Process
 *)

include Future_sig.Types

type 'a delayed = {
  (** Number of times it has been tapped by "is_ready" or "check_status". *)
  tapped : int;
  (** Number of times remaining to be tapped before it is ready. *)
  remaining : int;
  value : 'a;
}

type 'a promise =
  | Complete : 'a -> 'a promise
  | Complete_but_transformer_raised of (Process_types.info * exn)
    (** Delayed is useful for deterministic testing. Must be tapped by "is ready" or
     * "check_status" the remaining number of times before it is ready. *)
  | Delayed : 'a delayed -> 'a promise
    (** A future formed from two underlying futures. Calling "get" blocks until
     * both underlying are ready. *)
  | Merged : ('a t * 'b t * ('a -> 'b -> 'c)) -> 'c promise
    (** float is the time the Future was constructed. *)
  | Incomplete of float * Process_types.t * (string -> 'a)
and 'a t = 'a promise ref

let make process transformer =
  ref (Incomplete (Unix.time (), process, transformer))

let merge a b handler =
  ref (Merged (a, b, handler))

let of_value v = ref @@ Complete v

let delayed_value ~delays v =
  ref (Delayed {tapped = 0; remaining = delays; value = v;})

let error_to_string (info, e) =
  let info = Printf.sprintf "(%s [%s])"
    info.Process_types.name
    (String.concat ", " info.Process_types.args) in
  let status_string s = match s with
    | Unix.WEXITED i -> Printf.sprintf "(%s WEXITED %d)" info i
    | Unix.WSIGNALED i -> Printf.sprintf "(%s WSIGNALED %d)" info i
    | Unix.WSTOPPED i -> Printf.sprintf "(%s WSTOPPED %d)" info i
  in
  match e with
  | Process_failure (status, stderr) ->
    Printf.sprintf "Process_failure(%s, stderr: %s)" (status_string status) stderr
  | Timed_out (stdout , stderr) ->
    Printf.sprintf "Timed_out((stdout: %s) (stderr: %s))" stdout stderr
  | Process_aborted ->
    "Process_aborted"
  | Transformer_raised e ->
    Printf.sprintf "Transformer_raised(%s)" (Printexc.to_string e)

let error_to_exn e = raise (Failure e)

let rec get : 'a. ?timeout:int -> 'a t -> ('a, error) result =
  fun ?(timeout=30) promise -> match !promise with
  | Complete v -> Ok v
  | Complete_but_transformer_raised (info, e) ->
    Error (info, Transformer_raised e)
  | Delayed { value; remaining; _ } when remaining <= 0 ->
    Ok value
  | Delayed _ ->
    Error (Process_types.dummy.Process_types.info, Timed_out ("", "Delayed value not ready yet"))
  | Merged (a, b, handler) ->
    let open Core_result.Monad_infix in
    let start_t = Unix.time () in
    get ~timeout a >>= fun a ->
    let consumed_t = int_of_float @@ Unix.time () -. start_t in
    let timeout = timeout - consumed_t in
    get ~timeout b >>= fun b ->
    let result = handler a b in
    let () = promise := Complete result in
    Ok result
  | Incomplete (_, process, transformer) ->
    let info = process.Process_types.info in
    match Process.read_and_wait_pid ~timeout process with
    | Ok (stdout, _stderr) -> begin
      try
        let result = transformer stdout in
        let () = promise := Complete result in
        Ok result
      with
      | e ->
        let () = promise := (Complete_but_transformer_raised (info, e)) in
        Error (info, Transformer_raised e)
    end
    | Error (Process_types.Process_exited_abnormally
        (status, _, stderr)) ->
      Error (info, Process_failure (status, stderr))
    | Error (Process_types.Timed_out (stdout, stderr)) ->
      Error (info, Timed_out (stdout, stderr))
    | Error Process_types.Process_aborted_input_too_large ->
      Error (info, Process_aborted)

let get_exn ?timeout x = get ?timeout x
  |> Core_result.map_error ~f:error_to_exn
  |> Core_result.ok_exn

(** Must explicitly make recursive functions polymorphic. *)
let rec is_ready : 'a. 'a t -> bool = fun promise ->
  match !promise with
  | Complete _ | Complete_but_transformer_raised _ -> true
  | Delayed {remaining; _} when remaining <= 0 ->
    true
  | Delayed { tapped; remaining; value; } ->
    promise := Delayed { tapped = tapped + 1; remaining = remaining - 1; value; };
    false
  | Merged (a, b, _) ->
    is_ready a && is_ready b
  | Incomplete (_, process, _) ->
    Process.is_ready process

let merge_status stat_a stat_b handler =
  match stat_a, stat_b with
  | Complete_with_result (Ok va), Complete_with_result (Ok vb) ->
    Complete_with_result (Ok (handler va vb))
  | Complete_with_result (Error e), _
  | _, Complete_with_result (Error e) ->
    Complete_with_result (Error e)
  | In_progress age_a, In_progress age_b when age_a > age_b ->
    In_progress age_a
  | In_progress age, _
  | _, In_progress age ->
    In_progress age

(** Must explicitly make recursive function polymorphic. *)
let rec check_status : 'a. 'a t -> 'a status = fun promise ->
  match !promise with
  | Complete v ->
    Complete_with_result (Ok v)
  | Complete_but_transformer_raised (info, e) ->
    Complete_with_result (Error (info, Transformer_raised e))
  | Delayed { value; remaining; _ } when remaining <= 0 ->
    Complete_with_result (Ok value)
  | Delayed { tapped; remaining; value; } ->
    promise := Delayed { tapped = tapped + 1; remaining = remaining - 1; value; };
    In_progress (float_of_int tapped)
  | Merged (a, b, handler) ->
    merge_status (check_status a) (check_status b) handler
  | Incomplete (start_t, process, _) ->
    if Process.is_ready process then
      Complete_with_result (get promise)
    else
      let age = Unix.time () -. start_t in
      In_progress age
