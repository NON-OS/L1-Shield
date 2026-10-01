// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {AssociationSetRegistry} from "../../contracts/shield/AssociationSetRegistry.sol";
import {SplitFormat7} from "./SplitFormat7.sol";

/// @notice Settles one pinned format 7 proof on a pool DeployShapes made. The caller has already marked the
///         proof's note root known in pool storage (a pinned proof's notes come from fixture secrets
///         and cannot be deposited here); this publishes its association root and settles.
/// @dev env: POOL, PKG, PUBLICS, SHAPE (A, Ap or B), NPER, BLOB0, BLOB1.
contract SettleShapes is Script {
    uint256 internal constant WORDS = 12;

    function run() external {
        string memory shape = vm.envString("SHAPE");
        uint256 nq = keccak256(bytes(shape)) == keccak256("A") ? 19 : keccak256(bytes(shape)) == keccak256("Ap") ? 18 : 17;
        (bool ok, bytes memory whole) = SplitFormat7.whole(vm.readFileBinary(vm.envString("PKG")), nq, vm.envUint("NPER"));
        require(ok, "the proof does not cut");
        uint256[] memory words = _words(vm.parseJsonUintArray(vm.readFile(vm.envString("PUBLICS")), ".publics"));
        ShieldedPool pool = ShieldedPool(payable(vm.envAddress("POOL")));
        bytes[] memory blobs = new bytes[](2);
        blobs[0] = vm.readFileBinary(vm.envString("BLOB0"));
        blobs[1] = vm.readFileBinary(vm.envString("BLOB1"));
        ShieldedPool.ResidualExec memory r;
        r.path = new address[](0);

        vm.startBroadcast();
        AssociationSetRegistry reg = AssociationSetRegistry(address(pool.associationRegistry()));
        if (!reg.isRegisteredRoot(bytes32(words[1]))) reg.publishRoot(bytes32(words[1]), "");
        pool.settleBatch(whole, words, r, "", blobs);
        vm.stopBroadcast();

        require(pool.nullifierSpent(bytes32(words[2])) && pool.nullifierSpent(bytes32(words[3])), "not spent");
    }

    function _words(uint256[] memory L) internal pure returns (uint256[] memory w) {
        require(L.length == 36, "a statement is 36 limbs");
        w = new uint256[](WORDS);
        uint256[12] memory at = [uint256(0), 4, 8, 12, 16, 20, 24, 25, 26, 27, 28, 32];
        for (uint256 i = 0; i < WORDS; ++i) {
            if (i >= 6 && i <= 9) w[i] = L[at[i]];
            else if (i >= 10) for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (48 * l);
            else for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (64 * l);
        }
    }
}
