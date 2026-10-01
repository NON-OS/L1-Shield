// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IAssociationSetRegistry} from "../../contracts/shield/interfaces/IAssociationSetRegistry.sol";
import {AssociationSetRegistry} from "../../contracts/shield/AssociationSetRegistry.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";
import {RelayerRegistry, IRelayFeeCap} from "../../contracts/shield/RelayerRegistry.sol";
import {RootBounty, IRootCommitter} from "../../contracts/shield/RootBounty.sol";
import {Chunk} from "../../contracts/shield/verifier/shapes/CodeChunk.sol";
import {ShapesStraightEvaluatorAt} from "../../contracts/shield/verifier/shapes/ShapesStraightEvaluatorAt.sol";
import {ComposedStarkVerifierShapes, IShapeWalk} from "../../contracts/shield/verifier/shapes/ComposedStarkVerifierShapes.sol";
import {PrepareShapes_A} from "../../contracts/shield/verifier/shapes/PrepareShapes_A.sol";
import {PrepareShapes_Ap} from "../../contracts/shield/verifier/shapes/PrepareShapes_Ap.sol";
import {PrepareShapes_B} from "../../contracts/shield/verifier/shapes/PrepareShapes_B.sol";
import {WalkShapes_A} from "../../contracts/shield/verifier/shapes/WalkShapes_A.sol";
import {WalkShapes_Ap} from "../../contracts/shield/verifier/shapes/WalkShapes_Ap.sol";
import {WalkShapes_B} from "../../contracts/shield/verifier/shapes/WalkShapes_B.sol";
import {SplitFormat7} from "./SplitFormat7.sol";

interface IShapedPrepare {
    function shape() external view returns (V.Shape memory);
    function shapeId() external view returns (uint256);
}

/// @notice Deploys the 12-word stack from spec/shapes and hands it to the Safe: the circuit's evaluator, the
///         three query shapes' prepares and walks, the three-shape adapter, one pinned proof attested,
///         then the pool with its amount policy, the relayer registry and the root bounty.
/// @dev Nothing is deployed unless spec/shapes is the stack named by env: IMAGE_HASH (the evaluator image
///      the straight-line evaluator was compiled from), PERIODIC_ROOT (held by every walk), and
///      PARAM_A, PARAM_AP, PARAM_B (mapped to shapes 1, 2 and 3). Every shape must declare at least
///      FLOOR_BITS provable bits, and the pool checks the weakest again in its constructor.
///
///      env, required: FEE_ROUTER, GUARDIAN, IMAGE_HASH, PERIODIC_ROOT, PARAM_A, PARAM_AP, PARAM_B.
///      env, optional: SAFE (default the Sepolia Safe), HASHER (default: deploy PoseidonGoldilocksFast
///      from spec/poseidon-fast; HASHER_STANDARD=true deploys PoseidonGoldilocks instead), REGISTRY
///      (default: deploy one),
///      NOX_TOKEN and NOX_SCALE (default 1e9; without NOX_TOKEN only the native coin is ranged),
///      ETH_MIN_EXP 15, ETH_MAX_EXP 19, ETH_FEE 1e15, NOX_MIN_EXP 9, NOX_MAX_EXP 15, NOX_FEE 1e10,
///      SHIELD_BPS 25, UNSHIELD_BPS 25, BOUNTY 1e15, BOUNTY_INTERVAL 600, OPEN (default true),
///      SELFTEST (default spec/shapes/transfer-eth-shape1, a shape A proof).
///
///      The pool and its AmountPolicy are Ownable2Step: the Safe is left pending owner of both and
///      completes each with acceptOwnership. Until then the deployer owns them.
contract DeployShapes is Script {
    uint256 internal constant WORDS = 12;
    uint256 internal constant FLOOR_BITS = 80;
    uint256 internal constant N_PERIODIC = 59; // committed periodic columns of the 12-word circuit
    address internal constant SEPOLIA_SAFE = 0xD4251BA8bD4F68690BaB9f27d544819cFBE11854;

    struct Out {
        address evaluator;
        address verifier;
        address hasher;
        address registry;
        address pool;
        address policy;
        address relayers;
        address bounty;
        bytes32 digest;
    }

    Out internal o;
    bytes32[3] internal paramIds;
    uint256[] internal words;

    function run() external returns (Out memory) {
        require(keccak256(vm.readFileBinary("spec/shapes/image.bin")) == vm.envBytes32("IMAGE_HASH"), "spec/shapes is another image");
        paramIds = [vm.envBytes32("PARAM_A"), vm.envBytes32("PARAM_AP"), vm.envBytes32("PARAM_B")];
        string memory pj = vm.readFile("spec/shapes/params.json");
        require(
            vm.parseJsonBytes32(pj, ".A") == paramIds[0] && vm.parseJsonBytes32(pj, ".Ap") == paramIds[1]
                && vm.parseJsonBytes32(pj, ".B") == paramIds[2],
            "spec/shapes holds other parameter ids"
        );
        address safe = vm.envOr("SAFE", SEPOLIA_SAFE);

        vm.startBroadcast();
        _verifier();
        _pool(msg.sender);
        ShieldedPool(payable(o.pool)).transferOwnership(safe);
        AmountPolicy(o.policy).transferOwnership(safe);
        vm.stopBroadcast();

        require(
            ShieldedPool(payable(o.pool)).pendingOwner() == safe && AmountPolicy(o.policy).pendingOwner() == safe,
            "the Safe is not pending owner"
        );
        _log(safe);
        return o;
    }

    /// @dev The evaluator, the adapter with its three walks, checked, then one pinned proof attested.
    function _verifier() internal {
        string memory st = vm.envOr("SELFTEST", string("spec/shapes/transfer-eth-shape1"));
        (bool ok, bytes memory whole) = SplitFormat7.whole(vm.readFileBinary(string.concat(st, "/proof.bin")), 19, N_PERIODIC);
        require(ok, "the self-test proof does not cut as shape A");
        words = _words(vm.parseJsonUintArray(vm.readFile(string.concat(st, "/publics.json")), ".publics"));
        address[] memory at;
        (o.evaluator, at) = _evaluator();
        ComposedStarkVerifierShapes a = _adapter(IProgramFormEvaluator(o.evaluator), at, paramIds);
        o.verifier = address(a);
        _checkVerifier(a, paramIds);
        o.digest = a.attest(whole, words);
    }

    /// @dev The pool, owned by the deployer while it configures it, then its companions.
    function _pool(address me) internal {
        o.hasher = vm.envOr("HASHER", address(0));
        if (o.hasher == address(0)) o.hasher = _hasher();
        o.registry = vm.envOr("REGISTRY", address(0));
        if (o.registry == address(0)) o.registry = address(new AssociationSetRegistry());
        ShieldedPool pool = new ShieldedPool(
            me,
            IStarkVerifier(o.verifier),
            IPoseidonGoldilocks(o.hasher),
            IAssociationSetRegistry(o.registry),
            vm.envAddress("FEE_ROUTER"),
            uint16(vm.envOr("SHIELD_BPS", uint256(25))),
            uint16(vm.envOr("UNSHIELD_BPS", uint256(25))),
            1, // native scale: one unit is one wei
            WORDS,
            _selfTest(o.digest, words)
        );
        o.pool = address(pool);
        AmountPolicy policy = pool.amountPolicy();
        o.policy = address(policy);

        _ranges(pool, policy);
        policy.setGuardian(vm.envAddress("GUARDIAN"));
        if (vm.envOr("OPEN", true)) {
            pool.setOpenDeposits(true);
            pool.endBetaMode();
        }
        o.relayers = address(new RelayerRegistry(IRelayFeeCap(address(policy))));
        o.bounty = address(
            new RootBounty(
                IRootCommitter(address(pool)),
                vm.envOr("BOUNTY", uint256(1e15)),
                vm.envOr("BOUNTY_INTERVAL", uint256(600))
            )
        );
    }

    function _log(address safe) internal view {
        (uint256 conjectured, uint256 provable) = ComposedStarkVerifierShapes(o.verifier).soundnessBits();
        console2.log("ShapesStraightEvaluatorAt   ", o.evaluator);
        console2.log("verifier (three shapes) ", o.verifier);
        console2.log("hasher                  ", o.hasher);
        console2.log("association registry    ", o.registry);
        console2.log("ShieldedPool            ", o.pool);
        console2.log("AmountPolicy            ", o.policy);
        console2.log("RelayerRegistry         ", o.relayers);
        console2.log("RootBounty              ", o.bounty);
        console2.log("pending owner (Safe)    ", safe);
        console2.log("provable, conjectured   ", provable, conjectured);
        console2.logBytes32(o.digest);
    }

    /// @dev The circuit's composition at z, as straight-line code in three chunks. The evaluator's
    ///      constructor refuses chunks whose code hashes are not the ones it was generated with.
    function _evaluator() internal returns (address ev, address[] memory at) {
        at = new address[](3);
        for (uint256 k = 0; k < 3; ++k) {
            string memory f = string.concat("spec/shapes/chunk", vm.toString(k), ".hex");
            at[k] = address(new Chunk(vm.parseBytes(string.concat("0x", vm.readFile(f)))));
        }
        ev = _create("ShapesStraightEvaluatorAt", abi.encode(at));
    }

    /// @dev PoseidonGoldilocksFast from spec/poseidon-fast, whose constructor runs the pinned vectors
    ///      and deploys nothing if they fail. The pool's constructor checks it again.
    function _hasher() internal returns (address h) {
        if (vm.envOr("HASHER_STANDARD", false)) return address(new PoseidonGoldilocks());
        bytes memory init =
            vm.parseBytes(string.concat("0x", vm.readFile("spec/poseidon-fast/PoseidonGoldilocksFast.initcode.hex")));
        assembly {
            h := create(0, add(init, 0x20), mload(init))
        }
        require(h != address(0), "the fast hasher failed its vectors");
    }

    function _adapter(IProgramFormEvaluator ev, address[] memory chunks, bytes32[3] memory pid)
        internal
        returns (ComposedStarkVerifierShapes)
    {
        address[3] memory pr;
        pr[0] = _create("PrepareShapes_A", "");
        pr[1] = _create("PrepareShapes_Ap", "");
        pr[2] = _create("PrepareShapes_B", "");
        address[3] memory w;
        w[0] = _create("WalkShapes_A", abi.encode(pr[0]));
        w[1] = _create("WalkShapes_Ap", abi.encode(pr[1]));
        w[2] = _create("WalkShapes_B", abi.encode(pr[2]));
        bytes32[] memory code = _codeHashes(chunks, pr);
        (uint256[] memory ids, bytes32[] memory pids, ComposedStarkVerifierShapes.Shape[] memory s) = _shapes(w, pid);
        return ComposedStarkVerifierShapes(
            _create(
                "ComposedStarkVerifierShapes",
                abi.encode(ev, WORDS, address(0), ids, pids, s, vm.envBytes32("IMAGE_HASH"), code)
            )
        );
    }

    // queries, and the query grind as 8 chained searches of chunkBits: 8 x 25 = 28, 8 x 28 = 31, 8 x 30 = 33
    function _shapes(address[3] memory w, bytes32[3] memory pid)
        internal
        pure
        returns (uint256[] memory ids, bytes32[] memory pids, ComposedStarkVerifierShapes.Shape[] memory s)
    {
        s = new ComposedStarkVerifierShapes.Shape[](3);
        ids = new uint256[](3);
        pids = new bytes32[](3);
        uint16[3] memory q = [uint16(19), 18, 17];
        uint16[3] memory b = [uint16(25), 28, 30];
        for (uint256 i = 0; i < 3; ++i) {
            s[i] = ComposedStarkVerifierShapes.Shape(IShapeWalk(w[i]), q[i], b[i], 8);
            ids[i] = i + 1;
            pids[i] = pid[i];
        }
    }

    /// @dev The code hash each contract of the stack must carry, computed from the build: the chunk
    ///      files as they are, and each compiled runtime with its immutables filled by the addresses it
    ///      was constructed with. The adapter compares them with what is deployed.
    function _codeHashes(address[] memory chunks, address[3] memory pr)
        internal
        view
        returns (bytes32[] memory h)
    {
        h = new bytes32[](10);
        h[0] = keccak256(_runtime("ShapesStraightEvaluatorAt", chunks));
        for (uint256 k = 0; k < 3; ++k) {
            h[1 + k] = keccak256(vm.parseBytes(string.concat("0x", vm.readFile(string.concat("spec/shapes/chunk", vm.toString(k), ".hex")))));
        }
        string[3] memory prep = ["PrepareShapes_A", "PrepareShapes_Ap", "PrepareShapes_B"];
        string[3] memory walk = ["WalkShapes_A", "WalkShapes_Ap", "WalkShapes_B"];
        address[] memory one = new address[](1);
        for (uint256 i = 0; i < 3; ++i) {
            h[4 + 2 * i] = keccak256(_runtime(prep[i], new address[](0)));
            one[0] = pr[i];
            h[5 + 2 * i] = keccak256(_runtime(walk[i], one));
        }
    }

    /// @dev Every contract of the verifier stack is created from its default-profile artifact,
    ///      out/<name>.sol/<name>.json, the same file `_runtime` computes its expected code hash from.
    ///      A `new` expression would take whichever build the compiler grouped the script with: some
    ///      forge versions compile everything this script imports under ShieldedPool's one-run
    ///      profile, and that code differs from the build the hashes, the tests and the gas figures
    ///      describe.
    function _create(string memory name, bytes memory args) internal returns (address a) {
        bytes memory init = bytes.concat(vm.getCode(_artifact(name)), args);
        assembly {
            a := create(0, add(init, 0x20), mload(init))
        }
        require(a != address(0), string.concat(name, " did not deploy"));
    }

    function _artifact(string memory name) internal pure returns (string memory) {
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    /// @dev The compiled runtime of `name` (out/<name>.sol/<name>.json) with its immutables, taken in
    ///      declaration order, set to `values`.
    function _runtime(string memory name, address[] memory values) internal view returns (bytes memory code) {
        string memory j = vm.readFile(_artifact(name));
        code = vm.parseJsonBytes(j, ".deployedBytecode.object");
        string memory refs = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.keyExistsJson(j, refs) ? vm.parseJsonKeys(j, refs) : new string[](0);
        require(keys.length == values.length, "an immutable count differs from the build");
        uint256[] memory ids = new uint256[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            ids[i] = vm.parseUint(keys[i]);
        }
        for (uint256 i = 0; i < keys.length; ++i) {
            // declaration order is AST id order
            uint256 rank;
            for (uint256 k = 0; k < keys.length; ++k) {
                if (ids[k] < ids[i]) ++rank;
            }
            string memory at = string.concat(refs, ".", keys[i]);
            uint256 n = _count(j, at);
            for (uint256 m = 0; m < n; ++m) {
                string memory e = string.concat(at, "[", vm.toString(m), "]");
                uint256 start = vm.parseJsonUint(j, string.concat(e, ".start"));
                require(vm.parseJsonUint(j, string.concat(e, ".length")) == 32, "an immutable is not one word");
                bytes32 v = bytes32(uint256(uint160(values[rank])));
                assembly {
                    mstore(add(add(code, 0x20), start), v)
                }
            }
        }
    }

    function _count(string memory j, string memory at) internal view returns (uint256 n) {
        while (vm.keyExistsJson(j, string.concat(at, "[", vm.toString(n), "]"))) ++n;
    }

    /// @dev Three shapes; the three parameter ids name shapes 1, 2 and 3; every walk is bound to its
    ///      shape and holds PERIODIC_ROOT; every shape at FLOOR_BITS or more.
    function _checkVerifier(ComposedStarkVerifierShapes a, bytes32[3] memory ids) internal view {
        require(a.shapeCount() == 3, "the verifier does not hold three shapes");
        bytes32 root = vm.envBytes32("PERIODIC_ROOT");
        for (uint256 i = 0; i < 3; ++i) {
            require(a.shapeOfParams(ids[i]) == i + 1, "a parameter id does not name its shape");
            (IShapeWalk walk,,,) = a.shapeOf(i + 1);
            IShapedPrepare p = IShapedPrepare(walk.prep());
            require(p.shapeId() == i + 1, "a walk is bound to another shape");
            V.Shape memory sh = p.shape();
            require(sh.periodicRoot == root, "a walk holds another periodic root");
            require(sh.nPeriodic == N_PERIODIC, "a walk opens another number of periodic columns");
            (, uint256 provable) = a.soundnessBitsForShape(i + 1);
            require(provable >= FLOOR_BITS, "a shape is under the floor");
        }
        (, uint256 weakest) = a.soundnessBits();
        require(weakest >= FLOOR_BITS, "the verifier's weakest figure is under the floor");
    }

    /// @dev Every asset gets its range and flat fee before anything else can happen: the policy
    ///      refuses an asset without one.
    function _ranges(ShieldedPool pool, AmountPolicy policy) internal {
        address nox = vm.envOr("NOX_TOKEN", address(0));
        uint256 n = nox == address(0) ? 1 : 2;
        uint64[] memory ids = new uint64[](n);
        uint8[] memory mins = new uint8[](n);
        uint8[] memory maxs = new uint8[](n);
        uint256[] memory fees = new uint256[](n);
        ids[0] = 0;
        mins[0] = uint8(vm.envOr("ETH_MIN_EXP", uint256(15)));
        maxs[0] = uint8(vm.envOr("ETH_MAX_EXP", uint256(19)));
        fees[0] = vm.envOr("ETH_FEE", uint256(1e15));
        if (nox != address(0)) {
            ids[1] = pool.registerAsset(nox, vm.envOr("NOX_SCALE", uint256(1e9)));
            mins[1] = uint8(vm.envOr("NOX_MIN_EXP", uint256(9)));
            maxs[1] = uint8(vm.envOr("NOX_MAX_EXP", uint256(15)));
            fees[1] = vm.envOr("NOX_FEE", uint256(1e10));
        }
        policy.initRanges(ids, mins, maxs, fees);
    }

    // 36 limbs to 12 words: digests four 64-bit limbs low first, words 6 to 9 one limb each, and
    // the recipient and fee recipient 48 + 48 + 48 + 16 bits.
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

    function _selfTest(bytes32 digest, uint256[] memory publicWords)
        internal
        view
        returns (ShieldedPool.DeploymentSelfTest memory s)
    {
        // expected hashes come from the vector file, never from the hasher under test
        string memory j = vm.readFile("spec/launch-selftest.json");
        s.hash2Left = vm.parseJsonBytes32(j, ".hash2.left");
        s.hash2Right = vm.parseJsonBytes32(j, ".hash2.right");
        s.hash2Expected = vm.parseJsonBytes32(j, ".hash2.expected");
        s.fieldsInput = vm.parseJsonUintArray(j, ".hashFields.input");
        s.fieldsExpected = vm.parseJsonBytes32(j, ".hashFields.expected");
        s.proof = abi.encodePacked(digest);
        s.proofPublicInputs = publicWords;
        s.noteValue = vm.parseJsonUint(j, ".noteVector.value");
        s.noteAssetId = uint64(vm.parseJsonUint(j, ".noteVector.assetId"));
        s.noteOwnerCommit = vm.parseJsonBytes32(j, ".noteVector.ownerCommit");
        s.noteCommitmentExpected = vm.parseJsonBytes32(j, ".noteVector.commitment");
    }
}
