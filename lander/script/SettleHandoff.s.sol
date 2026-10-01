// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IShieldedPoolLite, IStarkVerifierLite, IAssociationSetRegistryLite} from "./IShieldedPoolLite.sol";
import {SplitFormat7} from "./SplitFormat7.sol";

/// @notice Settles one hand-off on a format 7 pool from the lander key. The shape comes from the
///         package header's parameter id, the proof is checked by the pool's own verifier before
///         anything is sent, and nothing is published on the hand-off's behalf: its association
///         root must already be registered.
/// @dev env: POOL, PKG (format 7 package, 40-byte NOXP header), PUBLICS (36 limbs, or 37 with the
///      not-before time), BLOB0, BLOB1, PARAM_A, PARAM_AP, PARAM_B, optional NPER (default 59) and WORDS
///      (the pool's wordsPerIntent: 12, or 13 for the not-before pool; default 12).
contract SettleHandoff is Script {
    uint256 internal constant HEADER = 40;

    function run() external {
        bytes memory pkg = vm.readFileBinary(vm.envString("PKG"));
        uint256 nq = _queries(pkg);
        (bool ok, bytes memory whole) = SplitFormat7.whole(pkg, nq, vm.envOr("NPER", uint256(59)));
        require(ok, "the proof does not cut");
        uint256[] memory words = _words(vm.parseJsonUintArray(vm.readFile(vm.envString("PUBLICS")), ".publics"));
        IShieldedPoolLite pool = IShieldedPoolLite(vm.envAddress("POOL"));
        require(IStarkVerifierLite(pool.verifier()).verifyBatch(whole, words), "the pool's verifier refuses this proof");
        require(IAssociationSetRegistryLite(pool.associationRegistry()).isRegisteredRoot(bytes32(words[1])), "the association root is not registered");
        bytes[] memory blobs = new bytes[](2);
        blobs[0] = vm.readFileBinary(vm.envString("BLOB0"));
        blobs[1] = vm.readFileBinary(vm.envString("BLOB1"));
        IShieldedPoolLite.ResidualExec memory r;
        r.path = new address[](0);
        uint40 before = pool.nextLeafIndex();
        vm.startBroadcast();
        pool.settleBatch(whole, words, r, "", blobs);
        vm.stopBroadcast();
        console2.log("leaves", before, "->", pool.nextLeafIndex());
    }

    /// The query count of the shape the header's parameter id names; any other id is refused.
    function _queries(bytes memory pkg) internal view returns (uint256) {
        require(pkg.length > HEADER && pkg[0] == "N" && pkg[1] == "O" && pkg[2] == "X" && pkg[3] == "P", "not a package proof");
        require(uint8(pkg[4]) == 7 && uint8(pkg[5]) == 0, "not a format 7 package");
        bytes32 id;
        assembly {
            id := mload(add(pkg, 40)) // bytes 8..39: the parameter id
        }
        if (id == vm.envBytes32("PARAM_A")) return 19;
        if (id == vm.envBytes32("PARAM_AP")) return 18;
        if (id == vm.envBytes32("PARAM_B")) return 17;
        revert("the parameter id is not one of the pool's three shapes");
    }

    function _words(uint256[] memory L) internal view returns (uint256[] memory w) {
        uint256 k = vm.envOr("WORDS", uint256(12));
        require(k == 12 || k == 13, "a pool is 12 or 13 words");
        require(L.length == (k == 13 ? 37 : 36), "the statement does not match the pool's width");
        w = new uint256[](k);
        uint256[13] memory at = [uint256(0), 4, 8, 12, 16, 20, 24, 25, 26, 27, 28, 32, 36];
        for (uint256 i = 0; i < k; ++i) {
            if ((i >= 6 && i <= 9) || i == 12) w[i] = L[at[i]];
            else if (i >= 10) for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (48 * l);
            else for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (64 * l);
        }
    }
}
