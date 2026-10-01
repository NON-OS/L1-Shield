// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ShapeGasHarness} from "./ShapeGas.t.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {ProductionDeepQuery, DeepQueryHarness} from "../../contracts/shield/verifier/ProductionDeepQuery.sol";

/// Batch cost of N transfers: each doubling of N adds one bit of log_domain, so per-query cost
/// at growing log_domain, times the measured chain factor, prices the batch.
contract BatchScalingTest is Test {
    uint256 constant PMOD = 0xFFFFFFFF00000001;
    /// on-chain walk over meter total for the frozen shape on Sepolia (61,670,941 / 29,552,320), rounded.
    uint256 constant CHAIN_FACTOR_BPS = 20_870;
    /// the settlement point: one inner is one transfer, log_trace_len 18, log_domain 26.
    uint256 constant SETTLE_LOG_DOMAIN = 26;
    uint256 constant WIDTH = 747;
    uint256 constant OUTER_QUERIES = 32;

    ShapeGasHarness hz = new ShapeGasHarness();
    DeepQueryHarness hd = new DeepQueryHarness();

    function _fp2(uint256 i) internal pure returns (F.Fp2 memory) {
        return F.Fp2((i * 2654435761 + 11) % PMOD, (i * 40503 + 7) % PMOD);
    }

    function _deep(uint256 width) internal view returns (uint256 g) {
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

    function _wide(uint256 width, uint256 depth) internal view returns (uint256) {
        uint256[] memory vals = new uint256[](width);
        for (uint256 i = 0; i < width; ++i) vals[i] = (i * 31337 + 5) % PMOD;
        bytes32[] memory path = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) path[i] = keccak256(abi.encode(i));
        return hz.wideAuth(bytes32(uint256(1)), 12345, vals, path);
    }

    function _ext(uint256 depth) internal view returns (uint256) {
        bytes32[] memory path = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) path[i] = keccak256(abi.encode(i));
        return hz.extAuth(bytes32(uint256(1)), 12345, _fp2(3), path);
    }

    /// the fold chase needs a valid chain, so it is interpolated from its measurements at 2^25,
    /// 2^26 and 2^27 (45,664, 47,016, 48,368): 1,352 per layer.
    function _fold(uint256 logDomain) internal pure returns (uint256) {
        return 47_016 + (logDomain - 26) * 1_352;
    }

    /// per-query cost at a domain.
    function _perQuery(uint256 logDomain) internal view returns (uint256) {
        uint256 layers = logDomain - 1;
        return _deep(WIDTH) + _wide(WIDTH, logDomain) + 2 * _ext(logDomain) + 2 * layers * _ext(logDomain)
            + _fold(logDomain);
    }

    /// Logs per-query cost against trace width. 747 is the join-split outer, 11,700 the naive
    /// depth-2 tree whose inner is itself a 747-column outer.
    function test_whatAWiderOuterWouldCost() public view {
        console2.log("width | per query at log_domain 26 | batch gas (chain) | vs 747");
        uint256 at747 = _perQueryAt(747, 26);
        for (uint256 i = 0; i < 4; ++i) {
            uint256 w = [uint256(747), 2000, 6200, 11700][i];
            uint256 pq = _perQueryAt(w, 26);
            console2.log(w, pq, (pq * OUTER_QUERIES * CHAIN_FACTOR_BPS) / 10_000, (pq * 100) / at747);
        }
    }

    function _perQueryAt(uint256 width, uint256 logDomain) internal view returns (uint256) {
        uint256 layers = logDomain - 1;
        return _deep(width) + _wide(width, logDomain) + 2 * _ext(logDomain) + 2 * layers * _ext(logDomain)
            + _fold(logDomain);
    }

    function test_whatABatchOfNTransfersCostsOnChain() public view {
        console2.log("N transfers | log_domain | batch gas (chain) | per transfer");
        uint256 base;
        for (uint256 k = 0; k <= 8; ++k) {
            uint256 n = 1 << k;
            uint256 logDomain = SETTLE_LOG_DOMAIN + k;
            uint256 batch = (_perQuery(logDomain) * OUTER_QUERIES * CHAIN_FACTOR_BPS) / 10_000;
            if (k == 0) base = batch;
            console2.log(n, logDomain, batch, batch / n);
        }
        // the batch is nearly flat in N, so the per-transfer cost falls close to 1/N.
        uint256 at256 = (_perQuery(SETTLE_LOG_DOMAIN + 8) * OUTER_QUERIES * CHAIN_FACTOR_BPS) / 10_000;
        assertLt(at256, (base * 13_000) / 10_000, "256 transfers must cost under 1.3x one transfer");
        assertGt(at256, base, "and more than one, since the domain does grow");
    }
}
