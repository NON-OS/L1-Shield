// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DiffBase} from "./DiffBase.sol";
import {GoldilocksCore as C} from "../../../contracts/shield/verifier/GoldilocksCore.sol";
import {GoldilocksCoreRef as R} from "../reference/GoldilocksCoreRef.sol";

interface ICore {
    function mul(uint256 a, uint256 b) external pure returns (uint256);
    function add(uint256 a, uint256 b) external pure returns (uint256);
    function sub(uint256 a, uint256 b) external pure returns (uint256);
    function neg(uint256 a) external pure returns (uint256);
    function pow(uint256 a, uint256 e) external pure returns (uint256);
    function inv(uint256 a) external pure returns (uint256);
    function mul2(uint256 a0, uint256 a1, uint256 b0, uint256 b1) external pure returns (uint256, uint256);
    function sqr2(uint256 a0, uint256 a1) external pure returns (uint256, uint256);
    function inv2(uint256 a0, uint256 a1) external pure returns (uint256, uint256);
    function fold2(uint256[7] calldata v) external pure returns (uint256, uint256);
}

contract CoreYul is ICore {
    function mul(uint256 a, uint256 b) external pure returns (uint256) { return C.mul(a, b); }
    function add(uint256 a, uint256 b) external pure returns (uint256) { return C.add(a, b); }
    function sub(uint256 a, uint256 b) external pure returns (uint256) { return C.sub(a, b); }
    function neg(uint256 a) external pure returns (uint256) { return C.neg(a); }
    function pow(uint256 a, uint256 e) external pure returns (uint256) { return C.pow(a, e); }
    function inv(uint256 a) external pure returns (uint256) { return C.inv(a); }
    function mul2(uint256 a0, uint256 a1, uint256 b0, uint256 b1) external pure returns (uint256, uint256) {
        return C.mul2(a0, a1, b0, b1);
    }
    function sqr2(uint256 a0, uint256 a1) external pure returns (uint256, uint256) { return C.sqr2(a0, a1); }
    function inv2(uint256 a0, uint256 a1) external pure returns (uint256, uint256) { return C.inv2(a0, a1); }
    function fold2(uint256[7] calldata v) external pure returns (uint256, uint256) {
        return C.fold2(v[0], v[1], v[2], v[3], v[4], v[5], v[6]);
    }
}

contract CoreRef is ICore {
    function mul(uint256 a, uint256 b) external pure returns (uint256) { return R.mul(a, b); }
    function add(uint256 a, uint256 b) external pure returns (uint256) { return R.add(a, b); }
    function sub(uint256 a, uint256 b) external pure returns (uint256) { return R.sub(a, b); }
    function neg(uint256 a) external pure returns (uint256) { return R.neg(a); }
    function pow(uint256 a, uint256 e) external pure returns (uint256) { return R.pow(a, e); }
    function inv(uint256 a) external pure returns (uint256) { return R.inv(a); }
    function mul2(uint256 a0, uint256 a1, uint256 b0, uint256 b1) external pure returns (uint256, uint256) {
        return R.mul2(a0, a1, b0, b1);
    }
    function sqr2(uint256 a0, uint256 a1) external pure returns (uint256, uint256) { return R.sqr2(a0, a1); }
    function inv2(uint256 a0, uint256 a1) external pure returns (uint256, uint256) { return R.inv2(a0, a1); }
    function fold2(uint256[7] calldata v) external pure returns (uint256, uint256) {
        return R.fold2(v[0], v[1], v[2], v[3], v[4], v[5], v[6]);
    }
}

/// GoldilocksCore against its Solidity twin on every entry point.
contract GoldilocksCoreDiffTest is DiffBase {
    address internal y;
    address internal r;

    function setUp() public {
        y = address(new CoreYul());
        r = address(new CoreRef());
    }

    function testFuzz_mul(uint256 s, uint256 a, uint256 b) public view {
        _same(y, r, abi.encodeCall(ICore.mul, (_edge(s, a), _edge(s >> 8, b))));
    }

    function testFuzz_add(uint256 s, uint256 a, uint256 b) public view {
        _same(y, r, abi.encodeCall(ICore.add, (_edge(s, a), _edge(s >> 8, b))));
    }

    function testFuzz_sub(uint256 s, uint256 a, uint256 b) public view {
        _same(y, r, abi.encodeCall(ICore.sub, (_edge(s, a), _edge(s >> 8, b))));
    }

    function testFuzz_neg(uint256 s, uint256 a) public view {
        _same(y, r, abi.encodeCall(ICore.neg, (_edge(s, a))));
    }

    function testFuzz_pow(uint256 s, uint256 a, uint256 e) public view {
        _same(y, r, abi.encodeCall(ICore.pow, (_edge(s, a), _edge(s >> 8, e))));
    }

    function testFuzz_inv(uint256 s, uint256 a) public view {
        (bool ok, bytes memory out) = _same(y, r, abi.encodeCall(ICore.inv, (_edge(s, a))));
        assertTrue(ok);
        uint256 v = abi.decode(out, (uint256));
        // and the shared answer is the true inverse
        if (_edge(s, a) % P != 0) assertEq(mulmod(v, _edge(s, a), P), 1);
    }

    function testFuzz_mul2(uint256 s, uint256 a0, uint256 a1, uint256 b0, uint256 b1) public view {
        _same(y, r, abi.encodeCall(ICore.mul2, (_edge(s, a0), _edge(s >> 8, a1), _edge(s >> 16, b0), _edge(s >> 24, b1))));
    }

    function testFuzz_sqr2(uint256 s, uint256 a0, uint256 a1) public view {
        _same(y, r, abi.encodeCall(ICore.sqr2, (_edge(s, a0), _edge(s >> 8, a1))));
    }

    function testFuzz_inv2(uint256 s, uint256 a0, uint256 a1) public view {
        _same(y, r, abi.encodeCall(ICore.inv2, (_edge(s, a0), _edge(s >> 8, a1))));
    }

    function testFuzz_fold2(uint256 s, uint256[7] memory v) public view {
        _same(
            y,
            r,
            abi.encodeCall(
                ICore.fold2,
                (
                    [
                        _edge(s, v[0]),
                        _edge(s >> 8, v[1]),
                        _edge(s >> 16, v[2]),
                        _edge(s >> 24, v[3]),
                        _edge(s >> 32, v[4]),
                        _edge(s >> 40, v[5]),
                        _edge(s >> 48, v[6])
                    ]
                )
            )
        );
    }

    /// The inversion chain at the values an off-by-one in the chain would miss first.
    function test_invAtTheEdges() public view {
        uint256[6] memory e = [uint256(0), 1, 2, P - 1, P - 2, 7];
        for (uint256 i = 0; i < e.length; ++i) _same(y, r, abi.encodeCall(ICore.inv, (e[i])));
        _same(y, r, abi.encodeCall(ICore.inv2, (0, P)));
        _same(y, r, abi.encodeCall(ICore.inv2, (P, 0)));
        _same(y, r, abi.encodeCall(ICore.inv2, (1, P + 1)));
    }
}
