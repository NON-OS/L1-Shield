// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MemoryProfileTest} from "./MemoryProfile.t.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {FixedEvaluator} from "./mocks/FixedEvaluator.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// The pool settles with the whole proof in its own transaction: `settleBatch` hands the adapter
/// `abi.encode(ONE_CALL, head, claims, queries, c0, c1)` and the adapter verifies it there. The
/// adapter's evaluator answers the artifact's comp_z, and the two trailing words are never read.
/// Same artifact as MemoryProfile, from `EMIT`.
contract OneCallSettleTest is MemoryProfileTest {
    StagedStarkVerifier internal a;

    function _adapter() internal returns (StagedStarkVerifier) {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = _v();
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        sd[0] = StagedStarkVerifier.Soundness({
            outerQueries: uint16(vm.parseJsonUint(st, ".outer_n_queries")),
            outerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".extra_blowup_bits")),
            outerGrindBits: uint16(vm.parseJsonUint(st, ".grind_bits")),
            innerQueries: uint16(vm.parseJsonUint(st, ".inner_n_queries")),
            innerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".inner_extra_blowup_bits")),
            innerGrindBits: 16
        });
        string memory cz = vm.readFile(string.concat(dir, "/compz.json"));
        FixedEvaluator ev =
            new FixedEvaluator(vm.parseUint(vm.parseJsonString(cz, ".c0")), vm.parseUint(vm.parseJsonString(cz, ".c1")));
        return new ComposedStarkVerifier(sizes, vs, sd, makeAddr("settler"), ev, 11);
    }

    /// the pool's 11 words, from the prover's 32 limbs: digests are four little-endian limbs,
    /// words 6..9 are single scalars. The inverse of PublicWords.publicsOf.
    function _words(uint256[] memory L) internal pure returns (uint256[] memory w) {
        w = new uint256[](11);
        uint256[11] memory at = [uint256(0), 4, 8, 12, 16, 20, 24, 25, 26, 27, 28];
        for (uint256 i = 0; i < 11; ++i) {
            if (i >= 6 && i <= 9) w[i] = L[at[i]];
            else for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (64 * l);
        }
    }

    function _whole() internal returns (bytes memory whole, uint256[] memory words) {
        Parts memory p = _parts(_shape());
        bytes memory all;
        for (uint256 i = 0; i < p.pieces.length; ++i) all = bytes.concat(all, p.pieces[i]);
        whole = abi.encode(a.ONE_CALL(), p.head, p.claims, all, p.c0, p.c1);
        words = _words(p.pubs);
    }

    function test_theAdapterVerifiesAWholeProofInOneCall() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        uint256 g = gasleft();
        bool ok = a.verifyBatch(whole, words);
        console2.log("adapter one call  ", g - gasleft());
        assertTrue(ok, "the whole proof was refused");
    }

    /// Any change to the batch is a different transcript, so the proof no longer opens.
    function test_refusesTheProofForADifferentBatch() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        words[6] ^= 1;
        try a.verifyBatch(whole, words) returns (bool ok) {
            assertFalse(ok, "accepted for a batch it does not prove");
        } catch {}
    }

    function test_refusesATamperedQuery() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        whole[whole.length - 300] ^= 0x01;
        try a.verifyBatch(whole, words) returns (bool ok) {
            assertFalse(ok, "accepted a tampered query");
        } catch {}
    }

    /// An offset pointing outside the proof must revert, not read past it.
    function test_refusesALyingOffset() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        assembly {
            mstore(add(whole, 0x60), 0xffffffff)
        }
        vm.expectRevert();
        a.verifyBatch(whole, words);
    }

    /// No verifier for the batch size: false, not a revert and not a lookup of size zero.
    function test_refusesAnUnregisteredBatchSize() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        uint256[] memory two = new uint256[](22);
        for (uint256 i = 0; i < 22; ++i) two[i] = words[i % 11];
        assertFalse(a.verifyBatch(whole, two));
    }

    /// What a node weighs for the whole settlement: `settleBatch` with the proof, two 1,178-byte
    /// client-data blobs and the type-2 envelope. A docs/17 blob is 1,186 bytes, 8 more each.
    function test_theSettlementFitsOneTransaction() public {
        a = _adapter();
        (bytes memory whole, uint256[] memory words) = _whole();
        bytes[] memory cd = new bytes[](2);
        cd[0] = new bytes(1178);
        cd[1] = new bytes(1178);
        ShieldedPool.ResidualExec memory r;
        bytes memory call = abi.encodeCall(ShieldedPool.settleBatch, (whole, words, r, "", cd));
        uint256 txBytes = call.length + 130;
        console2.log("settleBatch calldata", call.length);
        console2.log("transaction bytes   ", txBytes);
        console2.log("margin to 131,072   ", 131_072 - txBytes);
        assertLe(txBytes, 131_072, "the settlement does not fit one transaction");
    }
}
