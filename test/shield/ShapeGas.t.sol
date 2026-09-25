// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";
import {ProductionDeepQuery, DeepQueryHarness} from "../../contracts/shield/verifier/ProductionDeepQuery.sol";

/// A constant final layer as a degree-zero polynomial, for fixtures that fold to one value.
function _constFinal(F.Fp2 memory v) pure returns (F.Fp2[] memory o) {
    o = new F.Fp2[](1);
    o[0] = v;
}


/// Meters for per-query verification cost by shape. Each runs behind an external call so the
/// metered code starts with fresh memory. Path auth cost depends only on size.
contract ShapeGasHarness {
    uint256 constant PMOD = 0xFFFFFFFF00000001;

    function wideAuth(bytes32 root, uint256 idx, uint256[] memory vals, bytes32[] memory path)
        external
        view
        returns (uint256 g)
    {
        uint256 g0 = gasleft();
        MK.verifyPathWide(root, idx, vals, path);
        g = g0 - gasleft();
    }

    function extAuth(bytes32 root, uint256 idx, F.Fp2 memory leaf, bytes32[] memory path)
        external
        view
        returns (uint256 g)
    {
        uint256 g0 = gasleft();
        MK.verifyPathExt(root, idx, leaf, path);
        g = g0 - gasleft();
    }

    function fold(
        F.Fp2[] memory a,
        F.Fp2[] memory b,
        F.Fp2[] memory betas,
        uint256 q,
        F.Fp2 memory last,
        uint256 baseOmega,
        uint256 layers,
        uint256 n
    ) external view returns (uint256 g, bool ok) {
        uint256 g0 = gasleft();
        ok = ProductionAir.friFold(a, b, betas, q, _constFinal(last), baseOmega, layers, n, false);
        g = g0 - gasleft();
    }
}

contract ShapeGasTest is Test {
    ShapeGasHarness hz = new ShapeGasHarness();
    DeepQueryHarness hd = new DeepQueryHarness();

    uint256 constant PMOD = 0xFFFFFFFF00000001;
    uint256 constant SHIFT = 7;

    function _fp2(uint256 i) internal pure returns (F.Fp2 memory) {
        return F.Fp2((i * 2654435761 + 11) % PMOD, (i * 40503 + 7) % PMOD);
    }

    function _meterDeep(uint256 width) internal view returns (uint256 g) {
        uint256[] memory row = new uint256[](width);
        F.Fp2[] memory ood = new F.Fp2[](2 * width);
        F.Fp2[] memory coeffs = new F.Fp2[](2 * width + 1);
        for (uint256 i = 0; i < width; ++i) row[i] = (i * 7919 + 3) % PMOD;
        for (uint256 i = 0; i < 2 * width; ++i) ood[i] = _fp2(i);
        for (uint256 i = 0; i < 2 * width + 1; ++i) coeffs[i] = _fp2(i + 99);
        ProductionDeepQuery.Ctx memory ctx;
        ctx.z = _fp2(5);
        ctx.compZ = _fp2(6);
        ctx.x = 12345;
        ctx.g = F.fpPow(7, (PMOD - 1) >> 20);
        ctx.width = width;
        (, g) = hd.combineMetered(row, _fp2(8), ood, coeffs, ctx);
    }

    function _meterWideAuth(uint256 width, uint256 depth) internal view returns (uint256 g) {
        uint256[] memory vals = new uint256[](width);
        for (uint256 i = 0; i < width; ++i) vals[i] = (i * 31337 + 5) % PMOD;
        bytes32[] memory path = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) path[i] = keccak256(abi.encode(i));
        g = hz.wideAuth(bytes32(uint256(1)), 12345, vals, path);
    }

    function _meterExtAuth(uint256 depth) internal view returns (uint256 g) {
        bytes32[] memory path = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) path[i] = keccak256(abi.encode(i));
        g = hz.extAuth(bytes32(uint256(1)), 12345, _fp2(3), path);
    }

    struct FoldChain {
        F.Fp2[] a;
        F.Fp2[] b;
        F.Fp2[] betas;
        F.Fp2 last;
    }

    /// A fold chain valid layer by layer, so friFold walks the whole depth without an early exit.
    function _chain(uint256 layers, uint256 logDomain, uint256 q) internal view returns (FoldChain memory ch) {
        uint256 n = 1 << logDomain;
        uint256 baseOmega = F.fpPow(7, (PMOD - 1) >> logDomain);
        ch.a = new F.Fp2[](layers);
        ch.b = new F.Fp2[](layers);
        ch.betas = new F.Fp2[](layers);
        for (uint256 m = 0; m < layers; ++m) {
            ch.betas[m] = _fp2(m + 50);
            ch.a[m] = _fp2(m + 1);
            ch.b[m] = _fp2(m + 200);
        }
        for (uint256 m = 0; m < layers; ++m) {
            uint256 i = q % (n >> (m + 1));
            ch.last = _fold1(ch.a[m], ch.b[m], ch.betas[m], i, m, baseOmega);
            if (m + 1 < layers) {
                if (i < (n >> (m + 2))) ch.a[m + 1] = ch.last;
                else ch.b[m + 1] = ch.last;
            }
        }
    }

    function _meterFold(uint256 layers, uint256 logDomain) internal view returns (uint256 g) {
        FoldChain memory ch = _chain(layers, logDomain, 12345);
        uint256 baseOmega = F.fpPow(7, (PMOD - 1) >> logDomain);
        bool ok;
        (g, ok) = hz.fold(ch.a, ch.b, ch.betas, 12345, ch.last, baseOmega, layers, 1 << logDomain);
        require(ok, "constructed chain must close, else the meter is measuring an early exit");
    }

    function _fold1(F.Fp2 memory a, F.Fp2 memory b, F.Fp2 memory beta, uint256 i, uint256 m, uint256 baseOmega)
        internal
        pure
        returns (F.Fp2 memory)
    {
        uint256 inv2 = F.fpInv(2);
        uint256 x = F.fpPow(F.fpMul(SHIFT, F.fpPow(baseOmega, i)), uint256(1) << m);
        F.Fp2 memory even = F.mulBase(F.add(a, b), inv2);
        F.Fp2 memory odd = F.mulBase(F.mulBase(F.sub(a, b), inv2), F.fpInv(x));
        return F.add(even, F.mul(beta, odd));
    }

    function _row(string memory tag, uint256 width, uint256 logDomain, uint256 layers) internal view {
        uint256 d = _meterDeep(width);
        uint256 w = _meterWideAuth(width, logDomain);
        uint256 e = 2 * _meterExtAuth(logDomain);
        uint256 la = 2 * layers * _meterExtAuth(logDomain);
        uint256 f = _meterFold(layers, logDomain);
        console2.log(tag);
        console2.log("  deep combine      ", d);
        console2.log("  wide row auth     ", w);
        console2.log("  deep+comp ext auth", e);
        console2.log("  layer auths       ", la);
        console2.log("  fold chase        ", f);
        console2.log("  PER QUERY         ", d + w + e + la + f);
        console2.log("  x32 outer queries ", (d + w + e + la + f) * 32);
    }

    function test_perQueryCostAtBothShapes() public view {
        // Control: the frozen point with known real-proof numbers. Rate 1/2, 32 queries, 8 grind bits.
        _row("frozen 09-03  width 436  domain 2^25  24 folds  rate 1/2   40 bits", 436, 25, 24);
        // settlement: log_trace_len 18, extra blowup 3, so 2^23 base becomes 2^26. 144 bits.
        _row("settlement    width 747  domain 2^26  25 folds  rate 1/16 144 bits", 747, 26, 25);
        // Transfer-64: log_trace_len 19, base domain 2^24, extra blowup 3. The outer proves at
        // rate 1/16 whatever inner it aggregates, and 32 queries reach 144 bits only there.
        _row("transfer-64   width 747  domain 2^27  26 folds  rate 1/16 144 bits", 747, 27, 26);
    }
}
