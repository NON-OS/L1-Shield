// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase} from "./LaunchBase.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";

/// The two u32 section counts of a one-call head are not absorbed, so the walk requires each to
/// equal nq. Any other value is refused, so the head has one encoding per proof.
contract HeadSectionCountsTest is LaunchBase {
    function _parts() internal view returns (Cut memory c, uint256[] memory words, uint256 friAt, uint256 baseAt) {
        bytes memory p = vm.readFileBinary("spec/launch-honest/settlement.proof");
        c = _cut(p);
        words = _words(abi.decode(vm.parseJson(vm.readFile("spec/launch-honest/publics-array.json")), (uint256[])));
        baseAt = c.head.length - 4;
        friAt = baseAt - V.nonceBytes(v.shape(), _rounds(p, v.shape())) - 4;
    }

    function _u32At(bytes memory b, uint256 o) internal pure returns (uint256) {
        return uint256(uint8(b[o])) | (uint256(uint8(b[o + 1])) << 8) | (uint256(uint8(b[o + 2])) << 16)
            | (uint256(uint8(b[o + 3])) << 24);
    }

    function _with(bytes memory head, uint256 o, uint32 x) internal pure returns (bytes memory h) {
        h = bytes.concat(head);
        for (uint256 i = 0; i < 4; ++i) h[o + i] = bytes1(uint8(x >> (8 * i)));
    }

    function _wholeWith(Cut memory c, bytes memory head) internal view returns (bytes memory) {
        return abi.encode(a.ONE_CALL(), head, c.claims, c.queries, uint256(0), uint256(0));
    }

    /// The honest head carries nq in both counts and verifies.
    function test_theHonestHeadCarriesNqTwice() public view {
        (Cut memory c, uint256[] memory words, uint256 friAt, uint256 baseAt) = _parts();
        assertEq(_u32At(c.head, friAt), v.nq());
        assertEq(_u32At(c.head, baseAt), v.nq());
        assertTrue(a.verifyBatch(_wholeWith(c, c.head), words));
    }

    /// A FRI section count other than nq is refused.
    function test_aChangedFriCountIsRefused() public {
        (Cut memory c, uint256[] memory words, uint256 friAt,) = _parts();
        uint256 nq = v.nq();
        bytes memory whole = _wholeWith(c, _with(c.head, friAt, uint32(nq + 1)));
        vm.expectRevert(abi.encodeWithSelector(V.SectionCountMismatch.selector, nq + 1, nq));
        a.verifyBatch(whole, words);
    }

    /// A base section count other than nq is refused.
    function test_aChangedBaseCountIsRefused() public {
        (Cut memory c, uint256[] memory words,, uint256 baseAt) = _parts();
        uint256 nq = v.nq();
        bytes memory whole = _wholeWith(c, _with(c.head, baseAt, 0));
        vm.expectRevert(abi.encodeWithSelector(V.SectionCountMismatch.selector, 0, nq));
        a.verifyBatch(whole, words);
    }

    /// Every value of either count but nq is refused.
    function testFuzz_anyOtherCountIsRefused(uint32 x, bool fri) public {
        (Cut memory c, uint256[] memory words, uint256 friAt, uint256 baseAt) = _parts();
        uint256 nq = v.nq();
        vm.assume(x != nq);
        bytes memory whole = _wholeWith(c, _with(c.head, fri ? friAt : baseAt, x));
        vm.expectRevert(abi.encodeWithSelector(V.SectionCountMismatch.selector, uint256(x), nq));
        a.verifyBatch(whole, words);
    }
}
