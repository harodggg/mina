open Core
open Async

module Node = struct
  type t = {namespace: string; pod_id: string}

  let run_in_container node cmd =
    let kubectl_cmd =
      Printf.sprintf
        "kubectl -n %s -c coda exec -i $(kubectl get pod -n %s -l \"app=%s\" \
         -o name) -- %s"
        node.namespace node.namespace node.pod_id cmd
    in
    let%bind cwd = Unix.getcwd () in
    Cmd_util.run_cmd_exn cwd "sh" ["-c"; kubectl_cmd]

  let start ~fresh_state node =
    let open Deferred.Or_error.Let_syntax in
    let%bind () =
      if fresh_state then
        Deferred.map ~f:Or_error.return
          (run_in_container node "rm -rf .coda-config")
      else Deferred.Or_error.return ()
    in
    Deferred.map ~f:Or_error.return (run_in_container node "./start.sh")

  let stop node = run_in_container node "./stop.sh" >>| Or_error.return

  module Decoders = Graphql_lib.Decoders

  module Graphql = struct
    (* queries on localhost because of port forwarding *)
    let uri port =
      Uri.make
        ~host:Unix.Inet_addr.(localhost |> to_string)
        ~port ~path:"graphql" ()

    let get_pod_name t : string Deferred.Or_error.t =
      let args =
        [ "get"
        ; "pod"
        ; "-n"
        ; t.namespace
        ; "-l"
        ; sprintf "app=%s" t.pod_id
        ; "-o=custom-columns=NAME:.metadata.name"
        ; "--no-headers" ]
      in
      match%map Process.run_lines ~prog:"kubectl" ~args () with
      | Ok [pod_name] ->
          Ok pod_name
      | Ok [] ->
          Error (Error.of_string "get_pod_name: no result")
      | Ok _ ->
          Error (Error.of_string "get_pod_name: too many results")
      | Error e ->
          Error e

    (* default port is 3085, may need to be explicit if multiple daemons are running *)
    let set_port_forwarding ~logger t port =
      let open Deferred.Or_error.Let_syntax in
      let%bind name = get_pod_name t in
      let args =
        ["port-forward"; name; "--namespace"; t.namespace; string_of_int port]
      in
      [%log info] "Port forwarding using \"kubectl %s\"\n"
        String.(concat args ~sep:" ") ;
      let%bind.Deferred.Or_error.Let_syntax proc =
        Process.create ~prog:"kubectl" ~args ()
      in
      Exit_handlers.register_handler ~logger
        ~description:
          (sprintf "Kubectl port forwarder on pod %s, port %d" t.pod_id port)
        (fun () -> ignore Signal.(send kill (`Pid (Process.pid proc)))) ;
      Process.collect_stdout_and_wait proc

    module Client = Graphql_lib.Client.Make (struct
      let preprocess_variables_string = Fn.id

      let headers = String.Map.empty
    end)

    module Unlock_account =
    [%graphql
    {|
          mutation ($password: String!,
          $public_key: PublicKey!) {
             unlockAccount(input: {password: $password, publicKey: $public_key }) {
                 public_key: publicKey @bsDecoder(fn: "Decoders.public_key")
             }
          }
    |}]

    module Send_payment =
    [%graphql
    {|
          mutation ($sender: PublicKey!,
          $receiver: PublicKey!,
          $amount: UInt64!,
          $token: UInt64,
          $fee: UInt64!,
          $nonce: UInt32,
          $memo: String) {
          sendPayment(input:
            {from: $sender, to: $receiver, amount: $amount, token: $token, fee: $fee, nonce: $nonce, memo: $memo}) {
              payment {
        id
      }
    }
  }
  |}]
  end

  let send_payment ~logger t ~sender ~receiver ~amount ~fee =
    [%log info] "Running send_payment test"
      ~metadata:
        [("namespace", `String t.namespace); ("pod_id", `String t.pod_id)] ;
    let graphql_port = 3085 in
    let open Deferred.Or_error.Let_syntax in
    Deferred.don't_wait_for
      ( match%map.Deferred.Let_syntax
          Graphql.set_port_forwarding ~logger t graphql_port
        with
      | Ok _ ->
          (* not reachable, port forwarder does not terminate *)
          ()
      | Error err ->
          [%log fatal] "Error running k8s port forwarding"
            ~metadata:[("error", `String (Error.to_string_hum err))] ;
          failwith "Could not run k8s port forwarding" ) ;
    let sender_pk_str = Signature_lib.Public_key.Compressed.to_string sender in
    [%log info] "send_payment: unlocking account"
      ~metadata:[("sender_pk", `String sender_pk_str)] ;
    let unlock_sender_account_graphql () =
      let num_tries = 10 in
      let initial_delay_sec = 30.0 in
      let retry_delay_sec = 30.0 in
      let unlock_account_obj =
        Graphql.Unlock_account.make ~password:"naughty blue worm"
          ~public_key:(Graphql_lib.Encoders.public_key sender)
          ()
      in
      (* GraphQL not immediately available, retry as needed *)
      let rec go n =
        if n <= 0 then (
          [%log fatal] "unlock_sender_account_graphql: too many tries" ;
          failwith "unlock_sender_account_graphql: too many tries" )
        else
          let open Deferred.Let_syntax in
          match%bind
            (Graphql.Client.query unlock_account_obj)
              (Graphql.uri graphql_port)
          with
          | Ok _ ->
              [%log info] "unlock sender account succeeded" ;
              return (Ok ())
          | Error (`Failed_request err) ->
              [%log warn]
                "unlock_sender_account_graphql, Failed GraphQL request: %s, \
                 %d tries left"
                err (n - 1) ;
              let%bind () = after (Time.Span.of_sec retry_delay_sec) in
              go (n - 1)
          | Error (`Graphql_error err) ->
              [%log error] "unlock_sender_account_graphql, GraphQL error: %s"
                err ;
              return (Error (Error.of_string err))
      in
      let%bind.Deferred.Let_syntax () =
        after (Time.Span.of_sec initial_delay_sec)
      in
      go num_tries
    in
    let%bind () = unlock_sender_account_graphql () in
    let send_payment_graphql () =
      let num_tries = 10 in
      let initial_delay_sec = 30.0 in
      let retry_delay_sec = 30.0 in
      let send_payment_obj =
        Graphql.Send_payment.make
          ~sender:(Graphql_lib.Encoders.public_key sender)
          ~receiver:(Graphql_lib.Encoders.public_key receiver)
          ~amount:(Graphql_lib.Encoders.amount amount)
          ~fee:(Graphql_lib.Encoders.fee fee)
          ()
      in
      (* may have to retry if bootstrapping *)
      let open Deferred in
      let open Let_syntax in
      let rec go n =
        if n <= 0 then (
          [%log error] "send_payment_graphql: too many tries" ;
          return
            (Error (Error.of_string "send_payment_graphql: too many tries")) )
        else
          match%bind
            (Graphql.Client.query send_payment_obj) (Graphql.uri graphql_port)
          with
          | Ok result ->
              [%log info] "send payment GraphQL succeeded" ;
              return (Ok result)
          | Error (`Failed_request err) ->
              [%log warn]
                "send_payment_graphql, Failed GraphQL request: %s, %d tries \
                 left"
                err (n - 1) ;
              let%bind () = after (Time.Span.of_sec retry_delay_sec) in
              go (n - 1)
          | Error (`Graphql_error err) ->
              (* errors are not fatal here, like "still bootstrapping" *)
              [%log info]
                "send_payment_graphql, GraphQL error: %s, %d tries left" err
                (n - 1) ;
              let%bind () = after (Time.Span.of_sec retry_delay_sec) in
              go (n - 1)
      in
      let%bind () = after (Time.Span.of_sec initial_delay_sec) in
      go num_tries
    in
    let%map sent_payment_obj = send_payment_graphql () in
    let (`UserCommand id_obj) = (sent_payment_obj#sendPayment)#payment in
    let user_cmd_id = id_obj#id in
    [%log info] "Sent payment"
      ~metadata:[("user_command_id", `String user_cmd_id)] ;
    ()
end

type t =
  { namespace: string
  ; constraint_constants: Genesis_constants.Constraint_constants.t
  ; genesis_constants: Genesis_constants.t
  ; block_producers: Node.t list
  ; snark_coordinators: Node.t list
  ; archive_nodes: Node.t list
  ; testnet_log_filter: string }

let all_nodes {block_producers; snark_coordinators; archive_nodes; _} =
  block_producers @ snark_coordinators @ archive_nodes
