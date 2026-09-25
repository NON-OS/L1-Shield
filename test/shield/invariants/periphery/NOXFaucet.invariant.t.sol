// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NOXFaucet} from "../../../../contracts/faucet/NOXFaucet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// Drives NOXFaucet through random sequences of signed tickets relayed by third parties, unsigned
/// claims, replays, redirected tickets, tickets from a rotated-out key, pauses, signer rotations,
/// refills and time. Every call that should have been refused and was not is counted, and every
/// payout is checked against the caps, the epoch budget, the floor and the cooldown as it happens.
contract FaucetHandler is Test {
    uint128 public constant MAX_ETH = 0.05 ether;
    uint128 public constant MAX_NOX = 1_000e18;
    uint64 public constant COOLDOWN = 1 days;
    uint64 public constant EPOCH = 1 days;
    uint128 public constant EPOCH_ETH = 0.2 ether;
    uint128 public constant EPOCH_NOX = 5_000e18;
    uint256 public constant FLOOR = 0.1 ether;

    NOXFaucet public f;
    MockERC20 public nox;
    address public owner;
    uint256[2] public keys = [uint256(0xA11CE), uint256(0xB0B)];
    uint256 public current; // index of the key the faucet trusts
    address[] public recipients;
    address[] public relayers;

    mapping(address => uint64) public lastPaidAt;
    mapping(address => uint256) public ticketsRedeemed;
    mapping(uint256 => uint256) public ethPaidInEpoch;
    mapping(uint256 => uint256) public noxPaidInEpoch;
    uint256 public totalEthOut;
    uint256 public totalNoxOut;
    uint256 public ethIn;
    uint256 public noxInTotal;

    // the last ticket that paid, kept for replay
    address lastRecipient;
    uint256 lastE;
    uint256 lastN;
    uint256 lastNonce;
    uint256 lastDeadline;
    bytes lastSig;
    bool haveLast;

    uint256 public replayAccepted;
    uint256 public redirectAccepted;
    uint256 public staleSignerAccepted;
    uint256 public pausedPayout;
    uint256 public cooldownBroken;
    uint256 public capBroken;
    uint256 public budgetBroken;
    uint256 public floorBroken;
    uint256 public misdirected; // a payout that did not land in full with the named recipient
    uint256 public relayerProfited;
    uint256 public closedPathPaid;
    uint256 public successes;

    constructor(NOXFaucet f_, MockERC20 nox_, address owner_) {
        f = f_;
        nox = nox_;
        owner = owner_;
        for (uint256 i = 0; i < 5; i++) {
            recipients.push(address(uint160(0xC000 + i)));
            relayers.push(address(uint160(0xD000 + i)));
        }
    }

    function _sign(uint256 key, address to, uint256 e, uint256 n, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, f.claimDigest(to, e, n, nonce, deadline));
        return abi.encodePacked(r, s, v);
    }

    struct Snap {
        uint256 recEth;
        uint256 recNox;
        uint256 relEth;
        uint256 relNox;
        uint256 fEth;
        uint256 fNox;
    }

    function _snap(address rec, address rel) internal view returns (Snap memory s) {
        s = Snap(rec.balance, nox.balanceOf(rec), rel.balance, nox.balanceOf(rel), address(f).balance, nox.balanceOf(address(f)));
    }

    // Checks one successful payout against every bound, and records it.
    function _paid(address rec, address rel, Snap memory b) internal {
        successes++;
        uint256 pe = rec.balance - b.recEth;
        uint256 pn = nox.balanceOf(rec) - b.recNox;
        if (b.fEth - address(f).balance != pe || b.fNox - nox.balanceOf(address(f)) != pn) misdirected++;
        if (rel != rec && (rel.balance != b.relEth || nox.balanceOf(rel) != b.relNox)) relayerProfited++;
        if (pe > MAX_ETH || pn > MAX_NOX) capBroken++;
        if (pe != 0 && address(f).balance < FLOOR) floorBroken++;
        if (f.paused()) pausedPayout++;
        uint64 last = lastPaidAt[rec];
        if (last != 0 && block.timestamp < last + COOLDOWN) cooldownBroken++;
        lastPaidAt[rec] = uint64(block.timestamp);
        uint256 ep = block.timestamp / EPOCH;
        ethPaidInEpoch[ep] += pe;
        noxPaidInEpoch[ep] += pn;
        if (ethPaidInEpoch[ep] > EPOCH_ETH || noxPaidInEpoch[ep] > EPOCH_NOX) budgetBroken++;
        totalEthOut += pe;
        totalNoxOut += pn;
    }

    // ------------------------------------------------------------------ honest tickets

    function ticket(uint256 rs, uint256 ls, uint256 e, uint256 n, uint256 ttl) external {
        address rec = recipients[rs % recipients.length];
        address rel = relayers[ls % relayers.length];
        e = bound(e, 0, 2 * MAX_ETH);
        n = bound(n, 0, 2 * MAX_NOX);
        uint256 deadline = block.timestamp + bound(ttl, 0, 2 days);
        uint256 nonce = f.nonces(rec);
        bytes memory sig = _sign(keys[current], rec, e, n, nonce, deadline);
        Snap memory b = _snap(rec, rel);
        vm.prank(rel);
        try f.claimWithTicket(rec, e, n, nonce, deadline, sig) {
            _paid(rec, rel, b);
            ticketsRedeemed[rec]++;
            (lastRecipient, lastE, lastN, lastNonce, lastDeadline, lastSig, haveLast) =
                (rec, e, n, nonce, deadline, sig, true);
        } catch {}
    }

    function openClaim(uint256 rs) external {
        address rec = recipients[rs % recipients.length];
        bool open = f.openClaims();
        Snap memory b = _snap(rec, rec);
        vm.prank(rec);
        try f.claim() {
            if (!open) closedPathPaid++;
            _paid(rec, rec, b);
        } catch {}
    }

    // ------------------------------------------------------------------ hostile submissions

    /// the last ticket that paid, submitted again, after any amount of time and by any relayer.
    function replay(uint256 ls) external {
        if (!haveLast) return;
        address rel = relayers[ls % relayers.length];
        vm.prank(rel);
        try f.claimWithTicket(lastRecipient, lastE, lastN, lastNonce, lastDeadline, lastSig) {
            replayAccepted++;
        } catch {}
    }

    /// a valid ticket for one recipient, submitted naming another. The relayer names itself or a
    /// third address. The other recipient's nonce is used so only the signature can refuse it.
    function redirect(uint256 rs, uint256 ts, uint256 ls) external {
        address rec = recipients[rs % recipients.length];
        address to = ts % 2 == 0 ? relayers[ls % relayers.length] : recipients[ts % recipients.length];
        if (to == rec) return;
        address rel = relayers[ls % relayers.length];
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(keys[current], rec, MAX_ETH, MAX_NOX, f.nonces(rec), deadline);
        uint256 nonceTo = f.nonces(to);
        vm.prank(rel);
        try f.claimWithTicket(to, MAX_ETH, MAX_NOX, nonceTo, deadline, sig) {
            redirectAccepted++;
        } catch {}
        // and the same ticket with its amounts altered
        vm.prank(rel);
        try f.claimWithTicket(rec, MAX_ETH + 1, MAX_NOX, f.nonces(rec), deadline, sig) {
            redirectAccepted++;
        } catch {}
    }

    /// a correctly formed ticket signed by the key that is not the current signer.
    function staleSigner(uint256 rs, uint256 ls) external {
        address rec = recipients[rs % recipients.length];
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(keys[1 - current], rec, MAX_ETH, MAX_NOX, f.nonces(rec), deadline);
        uint256 nonce = f.nonces(rec);
        vm.prank(relayers[ls % relayers.length]);
        try f.claimWithTicket(rec, MAX_ETH, MAX_NOX, nonce, deadline, sig) {
            staleSignerAccepted++;
        } catch {}
    }

    // ------------------------------------------------------------------ owner and time

    function rotateSigner() external {
        current = 1 - current;
        vm.prank(owner);
        f.setSigner(vm.addr(keys[current]));
    }

    function togglePause() external {
        vm.startPrank(owner);
        if (f.paused()) f.unpause();
        else f.pause();
        vm.stopPrank();
    }

    function toggleOpen() external {
        vm.prank(owner);
        f.setOpenClaims(!f.openClaims());
    }

    function refill(uint256 e, uint256 n) external {
        e = bound(e, 0, 1 ether);
        n = bound(n, 0, 20_000e18);
        // a real transfer through receive(), as a funder would send it
        (bool ok,) = address(f).call{value: e}("");
        require(ok, "fund");
        nox.mint(address(f), n);
        ethIn += e;
        noxInTotal += n;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }
}

/// Invariants of NOXFaucet over random call sequences.
/// Run: forge test --match-contract NOXFaucetInvariants (5,000 runs of depth 200 each).
contract NOXFaucetInvariants is Test {
    NOXFaucet f;
    MockERC20 nox;
    FaucetHandler h;
    address owner = address(0x0117E);

    function setUp() public {
        vm.warp(1_700_000_000);
        nox = new MockERC20("NOX", "NOX");
        f = new NOXFaucet(
            IERC20(address(nox)), owner, vm.addr(0xA11CE), 0.05 ether, 1_000e18, 1 days, 1 days, 0.2 ether, 5_000e18
        );
        vm.prank(owner);
        f.setLimits(0.05 ether, 1_000e18, 1 days, 0.1 ether);
        vm.deal(address(f), 0.5 ether);
        nox.mint(address(f), 10_000e18);
        h = new FaucetHandler(f, nox, owner);
        vm.deal(address(h), 1e30);
        targetContract(address(h));
    }

    /// Payout bounds: no payout exceeded the per-claim caps, no epoch paid out more than its budget,
    /// no ETH payout took the faucet below its floor, and no address was paid twice inside its
    /// cooldown. Together these are the per-address and global limits on what a leaked key or a
    /// sybil farm can take.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_payoutsRespectCapsBudgetFloorAndCooldown() public view {
        assertEq(h.capBroken(), 0);
        assertEq(h.budgetBroken(), 0);
        assertEq(h.floorBroken(), 0);
        assertEq(h.cooldownBroken(), 0);
        assertEq(f.epochEthSpent() <= f.epochEthBudget() ? 0 : 1, 0);
        assertEq(f.epochNoxSpent() <= f.epochNoxBudget() ? 0 : 1, 0);
    }

    /// Tickets are single-use and bound to what was signed: no replayed ticket, no ticket submitted
    /// for a different recipient or amount, and no ticket from a rotated-out signer ever paid. Each
    /// recipient's nonce equals the number of its tickets that paid.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_ticketsAreSingleUseAndBoundToTheSigner() public view {
        assertEq(h.replayAccepted(), 0);
        assertEq(h.redirectAccepted(), 0);
        assertEq(h.staleSignerAccepted(), 0);
        for (uint256 i = 0; i < 5; i++) {
            address r = h.recipients(i);
            assertEq(f.nonces(r), h.ticketsRedeemed(r));
        }
    }

    /// A relayed claim cannot redirect funds: every payout left the faucet and arrived, to the wei,
    /// with the recipient named in the ticket, and the relayer's balances never moved. Nothing paid
    /// while paused, and the unsigned path never paid while closed.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_fundsOnlyReachTheNamedRecipient() public view {
        assertEq(h.misdirected(), 0);
        assertEq(h.relayerProfited(), 0);
        assertEq(h.pausedPayout(), 0);
        assertEq(h.closedPathPaid(), 0);
        assertEq(address(f).balance + h.totalEthOut(), 0.5 ether + h.ethIn());
        assertEq(nox.balanceOf(address(f)) + h.totalNoxOut(), 10_000e18 + h.noxInTotal());
    }
}
