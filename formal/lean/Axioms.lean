import Shield.Field.Basic
import Shield.Field.Fp2
import Shield.Arith.Goldilocks
import Shield.Arith.Fp2Impl
import Shield.Arith.LimbBalance
import Shield.Fri.Chain
import Shield.Fri.Fold
import Shield.Deep.Quotient
import Shield.Merkle.Binding
import Shield.Soundness.Fri
import Shield.Zk.Launch

/-! Prints the axioms of every main theorem. Run with `lake env lean Axioms.lean`.
The only axioms allowed are `propext`, `Classical.choice` and `Quot.sound`. -/

-- 1. Field
#print axioms Shield.Field.P_prime
#print axioms Shield.Field.seven_not_square
#print axioms Shield.Field.orderOf_seven
#print axioms Shield.Field.irreducible_X_sq_sub_seven
#print axioms Shield.Field.equivAdjoinRoot
#print axioms Shield.Field.inv_eq
#print axioms Shield.Field.mul_inv_formula
#print axioms Shield.Field.frobenius_eq_star
-- 2. Chained FRI inverses
#print axioms Shield.Fri.inv_mul_zeta
#print axioms Shield.Fri.zeta_inv_eq_cube
#print axioms Shield.Fri.inv_pow_four
#print axioms Shield.Fri.next_point
#print axioms Shield.Fri.inv_step
#print axioms Shield.Fri.ixStep_spec
-- 3. Radix-4 fold
#print axioms Shield.Fri.fold2_even_odd
#print axioms Shield.Fri.fold_quad
#print axioms Shield.Fri.exists_quad_decomposition
#print axioms Shield.Fri.fold2Raw_val
#print axioms Shield.Fri.quadFold_val
#print axioms Shield.Fri.quadFold_correct
-- 4. DEEP
#print axioms Shield.Deep.dvd_sub_C_iff
#print axioms Shield.Deep.deep_quotient
#print axioms Shield.Deep.combined_dvd_iff
#print axioms Shield.Deep.deep_eval
#print axioms Shield.Deep.deep_group
#print axioms Shield.Deep.bad_coefficient_unique
#print axioms Shield.Deep.bad_coefficient_card
#print axioms Shield.Deep.deep_far
-- 5. Limbs
#print axioms Shield.Limbs.room_forces_hi_bound
#print axioms Shield.Limbs.value_le
#print axioms Shield.Limbs.value_injective
#print axioms Shield.Limbs.bounded_value_zero_mod_p
#print axioms Shield.Limbs.unbounded_dummy_worth_p
#print axioms Shield.Limbs.limbwise_conservation
#print axioms Shield.Limbs.balanced_has_carry
#print axioms Shield.Limbs.closes_iff_balances
#print axioms Shield.Limbs.modular_balance_alone_creates_value
-- 6. Goldilocks as implemented
#print axioms Shield.Arith.isCanonicalLimb_iff
#print axioms Shield.Arith.canonicalEquiv
#print axioms Shield.Arith.isCanonicalDigest_iff
#print axioms Shield.Arith.fpAdd_spec
#print axioms Shield.Arith.fpSub_spec
#print axioms Shield.Arith.fpNeg_spec
#print axioms Shield.Arith.fpMul_spec
#print axioms Shield.Arith.fpInv_spec
#print axioms Shield.Arith.fpPow_spec
-- 7. Fp2 as implemented
#print axioms Shield.Arith.W2.eq_iff
#print axioms Shield.Arith.W2.isZero_iff
#print axioms Shield.Arith.W2.add_val
#print axioms Shield.Arith.W2.sub_val
#print axioms Shield.Arith.W2.neg_val
#print axioms Shield.Arith.W2.mul_val
#print axioms Shield.Arith.W2.square_val
#print axioms Shield.Arith.W2.mulBase_val
#print axioms Shield.Arith.W2.conjugate_val
#print axioms Shield.Arith.W2.conjugate_eq_frobenius
#print axioms Shield.Arith.W2.inv_val
-- 8. Merkle
#print axioms Shield.Merkle.index_lt_of_verify
#print axioms Shield.Merkle.verify_extracts_collision
#print axioms Shield.Merkle.opening_binding
#print axioms Shield.Merkle.binding_of_collisionFree
#print axioms Shield.Merkle.leaf_ne_node
#print axioms Shield.Merkle.leaf_node_confusion_is_collision
-- 9. FRI soundness arithmetic
#print axioms Shield.Soundness.reported_figures
#print axioms Shield.Soundness.johnson_query_bits
#print axioms Shield.Soundness.capacity_query_bits
#print axioms Shield.Soundness.certified_of_hyp
#print axioms Shield.Soundness.outer_eps_le
#print axioms Shield.Soundness.outer_eps_ge
#print axioms Shield.Soundness.inner_eps_le
-- 10. Zero knowledge, the rank condition
#print axioms Shield.Zk.card_zeros_div_le
#print axioms Shield.Zk.exists_minor_ne_zero
#print axioms Shield.Zk.le_rank_of_minor_ne_zero
#print axioms Shield.Zk.totalDegree_det_le
#print axioms Shield.Zk.exists_rank_minor
#print axioms Shield.Zk.rank_lemma
#print axioms Shield.Zk.DegLE.mul
#print axioms Shield.Zk.DegLE.layer
#print axioms Shield.Zk.deepCol_deg
#print axioms Shield.Zk.revealMatrix_degree
#print axioms Shield.Zk.quadFactor_map
#print axioms Shield.Zk.quot0_spec
#print axioms Shield.Zk.quot1_spec
#print axioms Shield.Zk.maskPoly_eval_z
#print axioms Shield.Zk.maskPoly_eval_gz
#print axioms Shield.Zk.maskPoly_eval_root
#print axioms Shield.Zk.deep_quotient_eval
#print axioms Shield.Zk.deep_quotient_eval'
#print axioms Shield.Zk.revealMatrix_eval
#print axioms Shield.Zk.finrank_range_comp_le
#print axioms Shield.Zk.condition_R_of_le
#print axioms Shield.Zk.launch_rank_failure
#print axioms Shield.Zk.launch_condition_R
#print axioms Shield.Zk.launch_rank_failure_eps
#print axioms Shield.Zk.package_rank_failure
#print axioms Shield.Zk.eps_lt
#print axioms Shield.Zk.eps_gt
#print axioms Shield.Zk.eps_not_lt_two_pow_neg_80
#print axioms Shield.Zk.sz_floor
#print axioms Shield.Zk.average_over_positions
