open Core
open Import
open Pickles_types
open Types
open Common
open Backend

(* The pairing-based "reduced" me-only contains the data of the standard me-only
   but without the wrap verification key. The purpose of this type is for sending
   pairing me-onlys on the wire. There is no need to send the wrap-key since everyone
   knows it. *)
module Pairing_based = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type ('s, 'sgs, 'bpcs) t =
        {app_state: 's; sg: 'sgs; old_bulletproof_challenges: 'bpcs}
      [@@deriving sexp, yojson, sexp, compare, hash, eq]
    end
  end]

  let prepare ~dlog_plonk_index {app_state; sg; old_bulletproof_challenges} =
    { Pairing_based.Proof_state.Me_only.app_state
    ; sg
    ; dlog_plonk_index
    ; old_bulletproof_challenges=
        Vector.map ~f:Ipa.Step.compute_challenges old_bulletproof_challenges }
end

module Dlog_based = struct
  module Challenges_vector = struct
    [%%versioned_asserted
    module Stable = struct
      module V1 = struct
        type t =
          Challenge.Constant.t Scalar_challenge.Stable.V1.t
          Bulletproof_challenge.Stable.V1.t
          Wrap_bp_vec.Stable.V1.t
        [@@deriving sexp, compare, yojson, hash, eq]

        let to_latest = Fn.id
      end

      module Tests = struct end
    end]

    module Prepared = struct
      type t = (Tock.Field.t, Tock.Rounds.n) Vector.t
    end
  end

  type 'max_local_max_branching t =
    ( Tock.Inner_curve.Affine.t
    , (Challenges_vector.t, 'max_local_max_branching) Vector.t )
    Dlog_based.Proof_state.Me_only.t

  module Prepared = struct
    type 'max_local_max_branching t =
      ( Tock.Inner_curve.Affine.t
      , (Challenges_vector.Prepared.t, 'max_local_max_branching) Vector.t )
      Dlog_based.Proof_state.Me_only.t
  end

  let prepare ({sg; old_bulletproof_challenges} : _ t) =
    { Dlog_based.Proof_state.Me_only.sg
    ; old_bulletproof_challenges=
        Vector.map ~f:Ipa.Wrap.compute_challenges old_bulletproof_challenges }
end
