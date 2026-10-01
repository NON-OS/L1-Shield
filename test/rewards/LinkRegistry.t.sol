// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LinkRegistry} from "../../contracts/rewards/LinkRegistry.sol";

contract LinkRegistryTest is Test {
    LinkRegistry reg;
    uint256 constant GENESIS = 1790812800; // 1 October 2026 00:00 UTC
    uint256 mainKey = 0xA11CE;
    address mainnet;
    address testnetA = address(0xA);
    address testnetB = address(0xB);

    function setUp() public {
        vm.warp(GENESIS - 1 days);
        reg = new LinkRegistry(GENESIS);
        mainnet = vm.addr(mainKey);
    }

    function _sig(uint256 key, address main, address test_) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, reg.linkDigest(main, test_, reg.nonces(main)));
        return abi.encodePacked(r, s, v);
    }

    function _link(address test_) internal {
        bytes memory sig = _sig(mainKey, mainnet, test_);
        vm.prank(test_);
        reg.link(mainnet, sig, false);
    }

    // -- the domain the mainnet wallet signs --------------------------------------------------------

    function test_domainIsMainnet() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("NOX testnet rewards"),
                keccak256("1"),
                uint256(1)
            )
        );
        assertEq(reg.domainSeparator(), expected);
    }

    // -- before genesis ---------------------------------------------------------------------------------

    function test_linkBeforeGenesisCountsFromEpochZero() public {
        _link(testnetA);
        LinkRegistry.Link memory l = reg.linkOf(mainnet);
        assertEq(l.testnet, testnetA);
        assertEq(l.fromEpoch, 0);
        assertEq(reg.mainnetOf(testnetA), mainnet);
    }

    function test_changeFreelyBeforeGenesis() public {
        _link(testnetA);
        _link(testnetB);
        assertEq(reg.linkOf(mainnet).testnet, testnetB);
        assertEq(reg.mainnetOf(testnetA), address(0));
        assertEq(reg.mainnetOf(testnetB), mainnet);
    }

    // -- after genesis -------------------------------------------------------------------------------------

    function test_linkAfterGenesisCountsFromNextEpoch() public {
        vm.warp(GENESIS + 3 * 7 days + 1);
        _link(testnetA);
        assertEq(reg.linkOf(mainnet).fromEpoch, 4);
    }

    function test_onceChangePerEpoch() public {
        vm.warp(GENESIS + 1);
        _link(testnetA);
        bytes memory sig = _sig(mainKey, mainnet, testnetB);
        vm.prank(testnetB);
        vm.expectRevert(abi.encodeWithSelector(LinkRegistry.AlreadyChangedThisEpoch.selector, uint64(0)));
        reg.link(mainnet, sig, false);

        vm.warp(GENESIS + 7 days + 1);
        _link(testnetB);
        assertEq(reg.linkOf(mainnet).testnet, testnetB);
        assertEq(reg.linkOf(mainnet).fromEpoch, 2);
    }

    function test_unlinkCountsAsTheEpochsChange() public {
        vm.warp(GENESIS + 1);
        _link(testnetA);
        vm.warp(GENESIS + 7 days + 1);
        vm.prank(testnetA);
        reg.unlink();
        bytes memory sig = _sig(mainKey, mainnet, testnetB);
        vm.prank(testnetB);
        vm.expectRevert(abi.encodeWithSelector(LinkRegistry.AlreadyChangedThisEpoch.selector, uint64(1)));
        reg.link(mainnet, sig, false);
    }

    function test_firstLinkInEpochZeroIsNotBlocked() public {
        vm.warp(GENESIS + 1);
        _link(testnetA);
        assertEq(reg.linkOf(mainnet).testnet, testnetA);
    }

    // -- consent and one to one ----------------------------------------------------------------------------

    function test_wrongSignerRefused() public {
        bytes memory sig = _sig(0xBAD, mainnet, testnetA);
        vm.prank(testnetA);
        vm.expectRevert(LinkRegistry.BadSignature.selector);
        reg.link(mainnet, sig, false);
    }

    function test_signatureForAnotherTestnetRefused() public {
        bytes memory sig = _sig(mainKey, mainnet, testnetA);
        vm.prank(testnetB);
        vm.expectRevert(LinkRegistry.BadSignature.selector);
        reg.link(mainnet, sig, false);
    }

    function test_replayRefused() public {
        bytes memory sig = _sig(mainKey, mainnet, testnetA);
        vm.prank(testnetA);
        reg.link(mainnet, sig, false);
        vm.prank(testnetA);
        reg.unlink();
        vm.prank(testnetA);
        vm.expectRevert(LinkRegistry.BadSignature.selector);
        reg.link(mainnet, sig, false);
    }

    function test_testnetCannotCarryTwoStakes() public {
        _link(testnetA);
        uint256 otherKey = 0xB0B;
        address other = vm.addr(otherKey);
        bytes memory sig = _sig(otherKey, other, testnetA);
        vm.prank(testnetA);
        vm.expectRevert(abi.encodeWithSelector(LinkRegistry.TestnetTaken.selector, mainnet));
        reg.link(other, sig, false);
    }

    function test_contractWalletStoredUnverified() public {
        address safe = address(0x5AFE);
        vm.prank(testnetA);
        reg.link(safe, hex"deadbeef", true);
        LinkRegistry.Link memory l = reg.linkOf(safe);
        assertTrue(l.contractWallet);
        assertEq(l.testnet, testnetA);
    }

    function test_unlinkWithoutLinkRefused() public {
        vm.prank(testnetA);
        vm.expectRevert(LinkRegistry.NotLinked.selector);
        reg.unlink();
    }

    function test_zeroMainnetRefused() public {
        vm.prank(testnetA);
        vm.expectRevert(LinkRegistry.ZeroAddress.selector);
        reg.link(address(0), "", true);
    }

    // -- properties --------------------------------------------------------------------------------------

    /// One mainnet address maps to at most one testnet address, and the reverse, after any sequence.
    function testFuzz_oneToOne(uint8[16] calldata ops) public {
        address[3] memory tests = [address(0x1001), address(0x1002), address(0x1003)];
        uint256[2] memory keys = [uint256(0xA1), uint256(0xA2)];
        for (uint256 i = 0; i < ops.length; ++i) {
            vm.warp(GENESIS + uint256(i) * 7 days + 1);
            uint8 op = ops[i];
            address t = tests[op % 3];
            uint256 k = keys[(op / 3) % 2];
            address m = vm.addr(k);
            if ((op / 6) % 2 == 0) {
                bytes memory sig = _sig(k, m, t);
                vm.prank(t);
                try reg.link(m, sig, false) {} catch {}
            } else {
                vm.prank(t);
                try reg.unlink() {} catch {}
            }
            for (uint256 j = 0; j < 2; ++j) {
                address mj = vm.addr(keys[j]);
                address tj = reg.linkOf(mj).testnet;
                if (tj != address(0)) assertEq(reg.mainnetOf(tj), mj);
            }
            for (uint256 j = 0; j < 3; ++j) {
                address mj = reg.mainnetOf(tests[j]);
                if (mj != address(0)) assertEq(reg.linkOf(mj).testnet, tests[j]);
            }
        }
    }
}
