// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The ONE_CALL chunks of a format 7 body (docs/04): 32-byte digests,
///         radix 8 (3 layers, final 256), nq queries, nPer committed periodic columns.
/// @dev body: head through the u32 query count | FRI groups | head tail | rows | claims | periodic
///      rows | streams. head = the first part + head tail (8 query nonces, 3 fold nonces, u32 row
///      width). claims = u32 count, the periodic claims at z, the u64 DEEP nonce.
///      queries = FRI groups + rows + periodic rows + streams. The same cut as Split6, at format 7 sizes.
library SplitFormat7 {
    // format 7 (stark_proofs proof_wire/shared.rs): the u32 query count precedes the FRI groups
    uint256 internal constant HEAD_A = 3 * 32 + 4 + 4 + 88 * 16 + 4 + 3 * 32 + 4 + 256 * 16 + 4; // 5716
    uint256 internal constant TAIL = 8 * 8 + 3 * 8 + 4; // 92
    uint256 internal constant FRI_PER_Q = 16 * 24;
    uint256 internal constant ROW_PER_Q = 8 * 44 + 16;

    function cut(bytes memory b, uint256 nq, uint256 nPer)
        internal
        view
        returns (bool ok, bytes memory head, bytes memory claims, bytes memory queries)
    {
        uint256 f = HEAD_A + nq * FRI_PER_Q;
        uint256 r = f + TAIL + nq * ROW_PER_Q;
        uint256 c = r + 4 + nPer * 16 + 8;
        if (b.length < c + nq * 8 * nPer) return (false, head, claims, queries);
        head = bytes.concat(_sub(b, 0, HEAD_A), _sub(b, f, f + TAIL));
        claims = _sub(b, r, c);
        queries = bytes.concat(_sub(b, HEAD_A, f), _sub(b, f + TAIL, r), _sub(b, c, b.length));
        ok = true;
    }

    /// @notice abi.encode of the adapter's ONE_CALL proof for a package (the 40-byte header: NOXP,
    ///         u16 format, u16 protocol, 32-byte parameter id; then the body), and whether it cut. The
    ///         parameter id rides in the first trailing word: it names the shape.
    function whole(bytes memory pkg, uint256 nq, uint256 nPer) internal view returns (bool ok, bytes memory out) {
        if (pkg.length < 40) return (false, out);
        bytes4 magic;
        uint16 format;
        bytes32 pid;
        assembly {
            magic := mload(add(pkg, 0x20))
            format := shr(240, mload(add(pkg, 0x24)))
            pid := mload(add(pkg, 0x28))
        }
        // NOXP, format 7 (u16 little-endian)
        if (magic != "NOXP" || format != 0x0700) return (false, out);
        bytes memory head;
        bytes memory claims;
        bytes memory queries;
        (ok, head, claims, queries) = cut(_sub(pkg, 40, pkg.length), nq, nPer);
        out = abi.encode(keccak256("NONOS-SHIELD-ONE-CALL-v1"), head, claims, queries, pid, uint256(0));
    }

    function _sub(bytes memory b, uint256 from, uint256 to) private view returns (bytes memory o) {
        o = new bytes(to - from);
        assembly {
            if iszero(staticcall(gas(), 0x04, add(add(b, 0x20), from), sub(to, from), add(o, 0x20), sub(to, from))) {
                revert(0, 0)
            }
        }
    }
}
