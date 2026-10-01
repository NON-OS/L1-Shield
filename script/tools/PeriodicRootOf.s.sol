// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";
import {EmitCodec} from "../shield/EmitCodec.sol";

/// Prints the root every periodic row of the proof in `EMIT` opens to, at each query's position.
/// Tooling only: a deployment pins the root it is given, never one read from a proof.
contract PeriodicRootOf is Script {
    function run() external view {
        string memory dir = vm.envString("EMIT");
        bytes memory p = vm.readFileBinary(string.concat(dir, "/settlement.proof"));
        V.Shape memory sh = _shape(dir);
        uint256[] memory idx = _positions(p, sh, dir);
        (, uint256[] memory rows,,,,) = _rows(p, sh);
        for (uint256 q = 0; q < sh.nq; ++q) {
            bytes32 leaf = MK.hashLeafWidePeriodicRaw(p, rows[q], sh.nPeriodic);
            R.Cursor memory pc = R.Cursor(rows[q] + sh.nPeriodic * 8);
            bytes32[] memory path = R.readPath(p, pc, sh.digestBytes);
            console2.logBytes32(MK.foldTo(leaf, idx[q], path, sh.digestBytes));
        }
    }

    function _shape(string memory dir) internal view returns (V.Shape memory sh) {
        string memory st = vm.readFile(string.concat(dir, "/structure.json"));
        string memory ly = vm.readFile(string.concat(dir, "/layout.json"));
        sh.nq = vm.parseJsonUint(st, ".outer_n_queries");
        sh.logDomain = vm.parseJsonUint(st, ".log_domain");
        sh.logTraceLen = vm.parseJsonUint(st, ".log_trace_len");
        sh.traceWidth = vm.parseJsonUint(st, ".trace_width");
        sh.nCoeffs = vm.parseJsonUint(st, ".n_coeffs");
        sh.grindBits = EmitCodec.grindBits(st, ly);
        sh.cosetShift = vm.parseJsonUint(st, ".coset_shift");
        sh.nPeriodic = vm.parseJsonUint(ly, ".outer_n_periodic");
        sh.nChal = vm.parseJsonUint(ly, ".n_chal");
        sh.regionWidth = vm.parseJsonUint(st, ".region_width");
        sh.digestBytes = vm.parseJsonUint(ly, ".digest_bytes");
        sh.friRadix = vm.parseJsonUint(ly, ".fri_radix");
        sh.finalAsCoefficients = vm.parseJsonBool(ly, ".final_layer_coefficients");
        sh.format5 = vm.parseJsonBool(ly, ".format5");
        sh.extChallenges = vm.keyExistsJson(ly, ".ext_challenges") && vm.parseJsonBool(ly, ".ext_challenges");
        sh.powerCoeffs = EmitCodec.powerCoeffs(ly);
        sh.powerDeep = EmitCodec.powerDeep(ly);
        sh.roundGrindBits = EmitCodec.roundGrindBits(ly);
        sh.finalSearches = EmitCodec.finalSearches(ly);
        sh.maskColumn = EmitCodec.maskColumn(st);
    }

    /// Each query's position: FRI's in format 5, the consistency draw otherwise.
    function _positions(bytes memory p, V.Shape memory sh, string memory dir)
        internal
        view
        returns (uint256[] memory idx)
    {
        uint256[] memory pubs =
            abi.decode(vm.parseJson(vm.readFile(string.concat(dir, "/publics-array.json"))), (uint256[]));
        (V.Head memory h, F.Fp2[] memory ood) = V.decode(p, sh);
        (,,,, uint256 so,) = V.sectionsOf(p, sh);
        R.Cursor memory c = R.Cursor(so + 4);
        h.periodicZ = new F.Fp2[](sh.nPeriodic);
        for (uint256 i = 0; i < sh.nPeriodic; ++i) {
            R.Fp2 memory v = R.readFp2(p, c);
            h.periodicZ[i] = F.Fp2(uint256(v.c0), uint256(v.c1));
        }
        V.Checkpoint memory ck = V.mainCheckpointFull(h, ood, sh, pubs);
        (, uint256[] memory cons, bytes32 seed) = V.mainResume(ck.state, h, sh);
        if (!sh.format5) return cons;
        (, idx) = V.friChallenges(h, sh, seed);
    }

    function _rows(bytes memory p, V.Shape memory sh)
        internal
        pure
        returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory, uint256, uint256)
    {
        return V.sectionsOf(p, sh);
    }
}
