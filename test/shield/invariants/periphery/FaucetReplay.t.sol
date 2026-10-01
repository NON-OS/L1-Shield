// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {console2} from "forge-std/Test.sol";
import "./NOXFaucet.invariant.t.sol";

/// The shrunk sequence a full run reported against invariant_fundsOnlyReachTheNamedRecipient,
/// replayed call by call: the faucet holds exactly its seed plus every refill, and nothing is misdirected.
contract FaucetReplay is NOXFaucetInvariants {
    function _hh() internal view returns (FaucetHandler) { return h; }
    function test_replayShrunk() public {
        FaucetHandler x = _hh();
        x.redirect(6842499455305821255448906707397743131285059, 690585832801966064347420, 90745743353831533413492387525118);
        x.replay(281474976710655);
        x.redirect(9223372034707292161, 12010, 1313373041);
        x.staleSigner(2685036, 7786766819);
        x.redirect(149284273724897581266561721, type(uint256).max - 1, type(uint256).max - 2);
        x.refill(16289179181536878264726726397297694001016852590603271, type(uint256).max - 3);
        x.replay(5176);
        x.togglePause();
        x.ticket(127, 115790322417210952336529717160220497262186272106556906860092653394915770695680, 98084882, 12031, 7331);
        x.redirect(497184970474989673933171080147345463114584577418762427146622366855, 73352545147510517317, 8449185957163529474291105077688540262);
        x.warp(137528492462096);
        x.ticket(type(uint256).max - 2, 13788455437082965154487851169667751510897673700689746496476342276339644, 966414544262977993, 1, 2272284030659679843908319);
        x.refill(63, 6930523728191367238852);
        x.redirect(2, 184, 184);
        x.replay(2391);
        console2.log("faucet ETH", address(f).balance);
        console2.log("totalEthOut", x.totalEthOut());
        console2.log("ethIn", x.ethIn());
        console2.log("misdirected", x.misdirected());
        console2.log("relayerProfited", x.relayerProfited());
        console2.log("pausedPayout", x.pausedPayout());
        console2.log("closedPathPaid", x.closedPathPaid());
        console2.log("replayAccepted", x.replayAccepted());
        console2.log("successes", x.successes());
        invariant_fundsOnlyReachTheNamedRecipient();
    }
}
