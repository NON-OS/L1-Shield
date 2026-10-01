// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {LaunchBase, LaunchReplay} from "./LaunchBase.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// Each rule's own work, measured in isolation: its form and the form it replaces, over the
/// launch counts. Each call is external, so the two sides pay the same overhead.
contract RuleWork {
    function independent(bytes32 s, uint256 n) external pure returns (bytes32) {
        TS.T memory t = TS.T(s);
        TS.challengeFp2Batch(t, n);
        return t.state;
    }

    function powers(bytes32 s, uint256 n) external pure returns (bytes32) {
        TS.T memory t = TS.T(s);
        TS.powers(TS.challengeFp2(t), n);
        return t.state;
    }

    function grinds(bytes32 s, uint64[] calldata nonces, uint32 bits) external pure returns (bytes32) {
        TS.T memory t = TS.T(s);
        for (uint256 i = 0; i < nonces.length; ++i) {
            if (!TS.verifyPow(t, nonces[i], bits)) revert();
        }
        return t.state;
    }
}

contract LaunchRuleGasTest is LaunchBase {
    function _gas(address to, bytes memory data) internal returns (uint256 g) {
        g = gasleft();
        (bool ok,) = to.call(data);
        g -= gasleft();
        require(ok, "measured call reverted");
    }

    RuleWork internal w;
    bytes32 internal constant S = keccak256("any state");

    function _powersDelta(uint256 n) internal returns (int256) {
        return int256(_gas(address(w), abi.encodeCall(w.powers, (S, n))))
            - int256(_gas(address(w), abi.encodeCall(w.independent, (S, n))));
    }

    // grinds with zero bits do the same hashing as any bound, and every nonce passes
    function _grindDelta(uint64[] memory nonces, uint256 against) internal returns (int256) {
        uint64[] memory base = new uint64[](against);
        return int256(_gas(address(w), abi.encodeCall(w.grinds, (S, nonces, 0))))
            - int256(_gas(address(w), abi.encodeCall(w.grinds, (S, base, 0))));
    }

    function _replayed() internal returns (LaunchReplay rp, Cut memory c, uint256[] memory limbs) {
        rp = new LaunchReplay();
        c = _cut(vm.readFileBinary("spec/launch-honest/settlement.proof"));
        limbs = abi.decode(vm.parseJson(vm.readFile("spec/launch-honest/publics-array.json")), (uint256[]));
    }

    function test_eachRulesGas() public {
        w = new RuleWork();
        V.Shape memory sh = v.shape();
        (LaunchReplay rp, Cut memory c, uint256[] memory limbs) = _replayed();
        LaunchReplay.Out memory o = rp.replay(sh, c.head, c.claims, limbs);

        console2.log("coeff_rule powers against independent draws, delta gas");
        console2.logInt(_powersDelta(sh.nCoeffs));
        console2.log("deep_rule powers against independent draws, delta gas");
        console2.logInt(_powersDelta(V.nDeepCoeffs(sh)));
        console2.log("round grind, one nonce per layer against none, delta gas");
        console2.logInt(_grindDelta(o.roundNonces, 0));
        console2.log("final grind, 8 searches against 1, delta gas");
        console2.logInt(_grindDelta(o.finalNonces, 1));

        uint256 g = gasleft();
        rp.replay(sh, c.head, c.claims, limbs);
        console2.log("whole transcript at launch, gas", g - gasleft());
    }
}
