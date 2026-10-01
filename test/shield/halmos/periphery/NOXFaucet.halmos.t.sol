// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NOXFaucet} from "../../../../contracts/faucet/NOXFaucet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// Symbolic proofs for the faucet's payout bounds, over every limit, budget, caller and time.
/// Run: FOUNDRY_PROFILE=halmos halmos --match-contract NOXFaucetHalmos
/// Payouts go through the unsigned claim(), which shares _dispense with tickets. Halmos cannot tell
/// which key signed, so ticket signatures are fuzzed in test/shield/invariants/periphery/
/// NOXFaucet.invariant.t.sol. The nonce check runs before signature recovery and is proven here.
contract NOXFaucetHalmos is SymTest, Test {
    address owner = address(0x0117E);
    address signer = address(0x5160);
    MockERC20 nox;
    NOXFaucet f;

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        f = new NOXFaucet(IERC20(address(nox)), owner, signer, 1 ether, 1000e18, 1 days, 1 days, 5 ether, 5000e18);
    }

    function _configure(
        uint128 maxEth,
        uint128 maxNox,
        uint64 cd,
        uint256 floor_,
        uint64 len,
        uint128 eBudget,
        uint128 nBudget,
        uint256 ethBal,
        uint256 noxBal
    ) internal {
        vm.assume(len > 0);
        vm.assume(ethBal < 2 ** 128 && noxBal < 2 ** 128);
        vm.startPrank(owner);
        f.setLimits(maxEth, maxNox, cd, floor_);
        f.setEpoch(len, eBudget, nBudget);
        f.setOpenClaims(true);
        vm.stopPrank();
        vm.deal(address(f), ethBal);
        nox.mint(address(f), noxBal);
    }

    function _user(address who) internal view {
        vm.assume(who != address(0) && who != address(f) && who != owner);
        vm.assume(uint160(who) > 0x10000); // not a precompile
        vm.assume(who.code.length == 0);
        vm.assume(who.balance < 2 ** 128); // an account's ETH cannot approach 2^256
    }

    /// One claim never pays more than the per-claim caps, more than the epoch budget, ETH below the
    /// floor, or NOX the faucet does not hold. Every limit is symbolic.
    function check_oneClaimRespectsEveryBound(
        address who,
        uint128 maxEth,
        uint128 maxNox,
        uint256 floor_,
        uint128 eBudget,
        uint128 nBudget,
        uint256 ethBal,
        uint256 noxBal
    ) public {
        _user(who);
        _configure(maxEth, maxNox, 1 days, floor_, 1 days, eBudget, nBudget, ethBal, noxBal);
        uint256 e0 = who.balance;
        vm.prank(who);
        (bool ok,) = address(f).call(abi.encodeCall(f.claim, ()));
        if (!ok) return;
        uint256 paidEth = who.balance - e0;
        uint256 paidNox = nox.balanceOf(who);
        assert(paidEth <= maxEth && paidNox <= maxNox);
        assert(paidEth <= eBudget && paidNox <= nBudget);
        assert(address(f).balance >= floor_ || paidEth == 0);
        assert(paidNox <= noxBal);
        assert(f.epochEthSpent() == paidEth && f.epochNoxSpent() == paidNox);
    }

    /// Two claims in one epoch, by any two addresses, together stay inside the epoch budget.
    function check_twoClaimsInAnEpochStayInsideTheBudget(
        address a,
        address b,
        uint128 maxEth,
        uint128 maxNox,
        uint128 eBudget,
        uint128 nBudget,
        uint256 dt
    ) public {
        _user(a);
        _user(b);
        vm.assume(a != b);
        _configure(maxEth, maxNox, 0, 0, 1 days, eBudget, nBudget, 2 ** 127, 2 ** 127);
        vm.warp(1 days * 1000);
        vm.prank(owner);
        f.setEpoch(1 days, eBudget, nBudget); // start the epoch at a known boundary
        vm.assume(dt < 1 days);
        uint256 ea = a.balance;
        uint256 eb = b.balance;
        vm.prank(a);
        (bool okA,) = address(f).call(abi.encodeCall(f.claim, ()));
        vm.warp(block.timestamp + dt);
        vm.prank(b);
        (bool okB,) = address(f).call(abi.encodeCall(f.claim, ()));
        vm.assume(okA || okB);
        uint256 eth = (a.balance - ea) + (b.balance - eb);
        uint256 nx = nox.balanceOf(a) + nox.balanceOf(b);
        assert(eth <= eBudget);
        assert(nx <= nBudget);
    }

    /// The same address cannot claim twice inside its cooldown, whatever the cooldown is set to.
    function check_theCooldownIsRespected(address who, uint64 cd, uint256 dt) public {
        _user(who);
        vm.assume(cd > 0);
        _configure(1 ether, 1000e18, cd, 0, 1 days, 100 ether, 100_000e18, 50 ether, 50_000e18);
        vm.warp(1_000_000);
        vm.prank(who);
        f.claim();
        vm.assume(dt < cd);
        vm.warp(block.timestamp + dt);
        vm.prank(who);
        (bool ok,) = address(f).call(abi.encodeCall(f.claim, ()));
        assert(!ok);
    }

    /// While paused, no claim of either kind pays anything, for any caller and any ticket.
    function check_pausedMeansNoPayout(
        address caller,
        address recipient,
        uint256 e,
        uint256 n,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) public {
        _user(caller);
        _configure(1 ether, 1000e18, 0, 0, 1 days, 100 ether, 100_000e18, 50 ether, 50_000e18);
        vm.prank(owner);
        f.pause();
        vm.prank(caller);
        (bool ok1,) = address(f).call(abi.encodeCall(f.claim, ()));
        vm.prank(caller);
        (bool ok2,) = address(f).call(abi.encodeCall(f.claimWithTicket, (recipient, e, n, nonce, deadline, sig)));
        assert(!ok1 && !ok2);
        assert(address(f).balance == 50 ether);
        assert(nox.balanceOf(address(f)) == 50_000e18);
    }

    /// A ticket whose nonce is not the recipient's current nonce is refused before its signature is
    /// even read. Because a successful ticket advances the nonce by one, a redeemed ticket can never
    /// be redeemed again.
    function check_aStaleOrFutureNonceIsRefused(
        address caller,
        address recipient,
        uint256 e,
        uint256 n,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) public {
        vm.assume(nonce != f.nonces(recipient));
        vm.prank(caller);
        (bool ok,) = address(f).call(abi.encodeCall(f.claimWithTicket, (recipient, e, n, nonce, deadline, sig)));
        assert(!ok);
    }

    /// An expired ticket is refused, whoever relays it.
    function check_anExpiredTicketIsRefused(address caller, address recipient, uint256 deadline, bytes calldata sig)
        public
    {
        vm.assume(deadline < block.timestamp);
        vm.prank(caller);
        (bool ok,) =
            address(f).call(abi.encodeCall(f.claimWithTicket, (recipient, 1, 1, f.nonces(recipient), deadline, sig)));
        assert(!ok);
    }

    /// Only the owner can rotate the signer, pause, unpause, change limits or budgets, open the
    /// unsigned path, or sweep. A stranger who could do any of these could drain the faucet.
    function check_onlyTheOwnerConfigures(address caller, address v, uint128 x, uint64 y, uint256 z) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        (bool a,) = address(f).call(abi.encodeCall(f.setSigner, (v)));
        (bool b,) = address(f).call(abi.encodeCall(f.setLimits, (x, x, y, z)));
        (bool c,) = address(f).call(abi.encodeCall(f.setEpoch, (y, x, x)));
        (bool d,) = address(f).call(abi.encodeCall(f.setOpenClaims, (true)));
        (bool e,) = address(f).call(abi.encodeCall(f.pause, ()));
        (bool g,) = address(f).call(abi.encodeCall(f.sweep, (v, z, z)));
        vm.stopPrank();
        assert(!a && !b && !c && !d && !e && !g);
        assert(f.signer() == signer);
    }
}
