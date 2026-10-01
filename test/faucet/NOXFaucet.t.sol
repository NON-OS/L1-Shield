// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NOXFaucet} from "../../contracts/faucet/NOXFaucet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestToken is ERC20 {
    constructor() ERC20("NOX", "NOX") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @dev Rejects ETH, to exercise the failed-send path.
contract RefusesEth {
    receive() external payable {
        revert("no");
    }
}

contract NOXFaucetTest is Test {
    NOXFaucet faucet;
    TestToken nox;

    uint256 signerKey = 0xA11CE;
    address signerAddr;
    address owner = address(0x0117E);
    address relayer = address(0xBEEF);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    uint128 constant MAX_ETH = 0.05 ether;
    uint128 constant MAX_NOX = 1_000e18;
    uint64 constant COOLDOWN = 1 days;
    uint64 constant EPOCH = 1 days;
    uint128 constant EPOCH_ETH = 0.2 ether;
    uint128 constant EPOCH_NOX = 5_000e18;

    function setUp() public {
        signerAddr = vm.addr(signerKey);
        nox = new TestToken();
        faucet = new NOXFaucet(
            IERC20(address(nox)), owner, signerAddr, MAX_ETH, MAX_NOX, COOLDOWN, EPOCH, EPOCH_ETH, EPOCH_NOX
        );
        nox.transfer(address(faucet), 100_000e18);
        vm.deal(address(faucet), 10 ether);
        vm.deal(relayer, 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _sign(address to, uint256 e, uint256 n, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 d = faucet.claimDigest(to, e, n, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, d);
        return abi.encodePacked(r, s, v);
    }

    function _claim(address to, uint256 e, uint256 n, uint256 nonce, uint256 deadline) internal {
        bytes memory sig = _sign(to, e, n, nonce, deadline);
        vm.prank(relayer);
        faucet.claimWithTicket(to, e, n, nonce, deadline, sig);
    }

    // ---------------------------------------------------------------- the point of the design

    function test_aRecipientWithZeroEthIsFundable() public {
        assertEq(alice.balance, 0, "alice starts with nothing");

        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);

        assertEq(alice.balance, MAX_ETH, "alice received ETH");
        assertEq(nox.balanceOf(alice), MAX_NOX, "alice received NOX");
        assertTrue(relayer != alice, "submitted by a third party, so alice never signed or paid");
    }

    function test_theRelayerReceivesNothing() public {
        uint256 relayerNox = nox.balanceOf(relayer);
        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(nox.balanceOf(relayer), relayerNox, "value goes to the ticket's address only");
    }

    // ---------------------------------------------------------------- signer compromise

    function test_aLeakedSignerCannotDrainTheFaucet() public {
        uint256 start = address(faucet).balance;

        for (uint256 i = 1; i <= 50; ++i) {
            address victim = address(uint160(0x10000 + i));
            bytes memory sig = _sign(victim, 100 ether, 1_000_000e18, 0, block.timestamp + 1 hours);
            vm.prank(relayer);
            try faucet.claimWithTicket(victim, 100 ether, 1_000_000e18, 0, block.timestamp + 1 hours, sig) {}
            catch {}
        }

        uint256 drained = start - address(faucet).balance;
        assertEq(drained, EPOCH_ETH, "a compromised signer loses exactly one epoch budget");
        assertLt(drained, start / 10, "and the faucet keeps the overwhelming majority of its balance");
        console2.log("faucet ETH before        :", start);
        console2.log("drained by a leaked key  :", drained);
        console2.log("faucet ETH after         :", address(faucet).balance);
    }

    function test_aTicketCannotRaiseItsOwnLimit() public {
        _claim(alice, 100 ether, 1_000_000e18, 0, block.timestamp + 1 hours);
        assertEq(alice.balance, MAX_ETH, "truncated to the per-claim ETH cap");
        assertEq(nox.balanceOf(alice), MAX_NOX, "truncated to the per-claim NOX cap");
    }

    function test_aLeakedSignerCannotStreamToOneAddress() public {
        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 1, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(NOXFaucet.StillCooling.selector, uint64(block.timestamp) + COOLDOWN)
        );
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 1, block.timestamp + 1 hours, sig);
    }

    function test_rotatingTheSignerInvalidatesOutstandingTickets() public {
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 days);
        address fresh = vm.addr(0xB0B0);
        vm.prank(owner);
        faucet.setSigner(fresh);

        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.BadSignature.selector);
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 days, sig);
    }

    // ---------------------------------------------------------------- ticket integrity

    function test_aTicketCannotBeReplayed() public {
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NOXFaucet.BadNonce.selector, 1, 0));
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);
    }

    function test_aTicketCannotBeRedirected() public {
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.BadSignature.selector);
        faucet.claimWithTicket(bob, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);
    }

    function test_anExpiredTicketIsRefused() public {
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, dl);
        vm.warp(dl + 1);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.TicketExpired.selector);
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, dl, sig);
    }

    function test_aTicketFromTheWrongKeyIsRefused() public {
        bytes32 d = faucet.claimDigest(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, d);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.BadSignature.selector);
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, abi.encodePacked(r, s, v));
    }

    function test_aTicketDoesNotCrossToAnotherFaucet() public {
        NOXFaucet other = new NOXFaucet(
            IERC20(address(nox)), owner, signerAddr, MAX_ETH, MAX_NOX, COOLDOWN, EPOCH, EPOCH_ETH, EPOCH_NOX
        );
        nox.transfer(address(other), 10_000e18);
        vm.deal(address(other), 1 ether);

        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.BadSignature.selector);
        other.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);
    }

    // ---------------------------------------------------------------- cooldown and epochs

    function test_theCooldownExpires() public {
        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.warp(block.timestamp + COOLDOWN);
        _claim(alice, MAX_ETH, MAX_NOX, 1, block.timestamp + 1 hours);
        assertEq(alice.balance, uint256(MAX_ETH) * 2, "two claims a cooldown apart");
    }

    function test_theEpochBudgetRefills() public {
        for (uint256 i = 1; i <= 4; ++i) {
            address v = address(uint160(0x20000 + i));
            _claim(v, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        }
        assertEq(faucet.epochEthSpent(), EPOCH_ETH, "ETH budget exhausted");

        // the NOX budget still has one claim in it, so the fifth is trimmed to NOX only
        address fifth = address(0x20005);
        _claim(fifth, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(fifth.balance, 0, "no ETH left this epoch");
        assertEq(nox.balanceOf(fifth), MAX_NOX, "but the NOX leg still pays");

        // both budgets are spent, so the sixth claim reverts
        address sixth = address(0x20006);
        bytes memory sig = _sign(sixth, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.EpochExhausted.selector);
        faucet.claimWithTicket(sixth, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);

        vm.warp(block.timestamp + EPOCH);
        _claim(sixth, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(sixth.balance, MAX_ETH, "the next epoch pays again with no owner action");
    }

    function test_aPartialClaimIsTrimmedNotRefused() public {
        for (uint256 i = 1; i <= 3; ++i) {
            _claim(address(uint160(0x30000 + i)), MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        }
        uint256 noxLeft = faucet.epochNoxBudget() - faucet.epochNoxSpent();
        assertEq(noxLeft, EPOCH_NOX - 3 * MAX_NOX);

        address last = address(0x30009);
        _claim(last, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(nox.balanceOf(last), MAX_NOX, "still a full NOX claim");

        assertEq(faucet.epochEthSpent(), EPOCH_ETH);
    }

    // ---------------------------------------------------------------- the floor

    function test_theFaucetWillNotSpendBelowItsFloor() public {
        vm.prank(owner);
        faucet.setLimits(MAX_ETH, MAX_NOX, COOLDOWN, 9.99 ether); // only 0.01 spendable

        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(alice.balance, 0.01 ether, "trimmed to what sits above the floor");
        assertEq(address(faucet).balance, 9.99 ether, "the floor is intact");

        vm.warp(block.timestamp + COOLDOWN + 1);
        bytes memory sig = _sign(bob, MAX_ETH, 0, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.NothingToPay.selector);
        faucet.claimWithTicket(bob, MAX_ETH, 0, 0, block.timestamp + 1 hours, sig);
    }

    // ---------------------------------------------------------------- open mode

    function test_openClaimsAreOffByDefault() public {
        vm.prank(alice);
        vm.expectRevert(NOXFaucet.OpenClaimsDisabled.selector);
        faucet.claim();
    }

    function test_openClaimsStillRespectTheCooldown() public {
        vm.prank(owner);
        faucet.setOpenClaims(true);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        faucet.claim();
        assertEq(nox.balanceOf(alice), MAX_NOX);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(NOXFaucet.StillCooling.selector, uint64(block.timestamp) + COOLDOWN)
        );
        faucet.claim();
    }

    // ---------------------------------------------------------------- failure modes

    function test_aRecipientThatRefusesEthRevertsTheWholeClaim() public {
        address bad = address(new RefusesEth());
        bytes memory sig = _sign(bad, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(NOXFaucet.EthSendFailed.selector);
        faucet.claimWithTicket(bad, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);

        assertEq(nox.balanceOf(bad), 0, "the NOX leg rolled back too");
        assertEq(faucet.lastClaimAt(bad), 0, "the cooldown was not consumed by a failed claim");
        assertEq(faucet.nonces(bad), 0, "and the nonce was not burned");
    }

    function test_pauseStopsBothPaths() public {
        vm.prank(owner);
        faucet.pause();
        bytes memory sig = _sign(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        faucet.claimWithTicket(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours, sig);

        vm.prank(owner);
        faucet.unpause();
        _claim(alice, MAX_ETH, MAX_NOX, 0, block.timestamp + 1 hours);
        assertEq(alice.balance, MAX_ETH);
    }

    function test_onlyTheOwnerTurnsTheKnobs() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        faucet.setSigner(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        faucet.setLimits(1, 1, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        faucet.sweep(alice, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        faucet.pause();
        vm.stopPrank();
    }

    function test_ownershipHandoverIsTwoStep() public {
        vm.prank(owner);
        faucet.transferOwnership(alice);
        assertEq(faucet.owner(), owner, "not until it is accepted");
        vm.prank(alice);
        faucet.acceptOwnership();
        assertEq(faucet.owner(), alice);
    }

    // ---------------------------------------------------------------- the UI's view

    function test_quoteMatchesWhatAClaimActuallyPays() public {
        (bool ok,, uint256 qEth, uint256 qNox, uint256 qNonce,,) = faucet.quote(alice);
        assertTrue(ok, "claimable before");
        assertEq(qNonce, 0);

        _claim(alice, qEth, qNox, qNonce, block.timestamp + 1 hours);
        assertEq(alice.balance, qEth, "quote predicted the ETH exactly");
        assertEq(nox.balanceOf(alice), qNox, "quote predicted the NOX exactly");

        (bool ok2, uint64 next,,, uint256 n2,,) = faucet.quote(alice);
        assertFalse(ok2, "not claimable during the cooldown");
        assertEq(next, uint64(block.timestamp) + COOLDOWN);
        assertEq(n2, 1, "and the UI sees the next nonce");
    }

    function test_quoteReportsAPausedFaucet() public {
        vm.prank(owner);
        faucet.pause();
        (bool ok,,,,,,) = faucet.quote(alice);
        assertFalse(ok, "a paused faucet must not look claimable");
    }

    function test_fundingEmitsAndCounts() public {
        vm.deal(bob, 5 ether);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(faucet));
        emit NOXFaucet.Funded(bob, 1 ether);
        (bool ok,) = address(faucet).call{value: 1 ether}("");
        assertTrue(ok);
        (uint256 e,) = faucet.reserves();
        assertEq(e, 11 ether);
    }
}
