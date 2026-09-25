// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LaunchProgram
/// @notice The program-form blob of `gen_program_air.py`, split: transition part by hash, boundary part inline.
/// @dev Written by `script/tools/program_form_blob.py`. Transition part 14074 bytes (2802 ops, 38 outputs),
///      boundary part 844 bytes (62 boundaries on 44 rows).
library LaunchProgram {
    /// @notice keccak256 of the transition part the data contract must hold.
    bytes32 internal constant TAPE_HASH = 0x21dd9f3614d7159308b5fd99bf0f7b294428e807408e7876f423d8543ff2a08f;
    /// @notice Length of the transition part, in bytes.
    uint256 internal constant TAPE_LENGTH = 14074;
    /// @notice keccak256 of the whole blob, transition part then boundary part.
    bytes32 internal constant PROGRAM_HASH = 0x73e6c39ab9bf995da6971568b6f73a93114adad19ea9e6ac8c1ac7b314092cb7;
    /// @notice Challenge inputs the tape reads past the frame and the periodic claims.
    uint256 internal constant N_CHALLENGES = 4;
    /// @notice keccak256 of the image the evaluator is deployed with, spec/launch-program/image.bin.
    bytes32 internal constant IMAGE_HASH = 0x4b138b8b3087493eac15bd2ddc2878114a2efe15f41ca96b9473b49b0d116e69;

    /// @notice The boundary part of the blob.
    bytes internal constant BOUNDARIES =
        hex"0000000000000001ec5b6b809357f1b0224c5ff6a93eb390d9ae9848d24a3f41c589c353d9d0049b8fd00993ca1d8b6e"
        hex"01268e9d8e04498c7d82810457076fdc455f8fdcf378536ada426076688dbe79d9730adad33ddb0cbe8bf561efb82c87"
        hex"dbb0a56f9a1aa000e67dcaa8ce017728181c3bf7df19048d69ba9a6760f6061f616884339c3ac74149a6ef3db51b86e9"
        hex"6fee51f39a32aaf9dec65ed05bb42cd9486547519ac8c766c7d6c99eeee94b9ab00308cb200a6b9d1937a762165a2e7c"
        hex"d76114bb7d3cb8f6ef5d11fb4a32f4b9fb28c27aaa349eb321baf0967cd5a6b07cbca9c1b637b6ec975f7ad3b2ba38d3"
        hex"2a348c3183f1d76a563efdeec494cacfbcd693cdf91768ae907907c8f47b0120fbbba4a36c95fa9c97e80453cec35190"
        hex"c5251ab819c81f8783496495774c7bfbfb755d5e1ab284465e772775d8cf5aecc607a6bc9106fbb39d1b688e30718e63"
        hex"a29548a34debc5a1f45fab147dc164330000000000000000000000000400000000000000000000000000010000000000"
        hex"00000000000002000000000000000000040003000000000053504e4404000400000000004e554c4c0500030000000000"
        hex"00000000040005000000000053504e4404000600000000004e554c4c0500050000000000000000000000070100000008"
        hex"0101000009010200000a010300000b010400000c010500000d010600000e010700000f01080000100109000011010a00"
        hex"0012010b000013010c000014010d000015010e000016010f00001701100000180111000019011200001a011300001b01"
        hex"1400001c011500001d011600001e011700001f01180000200119000021011a000022011b000023011c000024011d0000"
        hex"25011e000026011f00002701200000280121000029012200002a01232200000000000000000000012300000000000000"
        hex"0000000022002b00000000000000000123002b0000000000000000002400000000000000000000012500000000000000"
        hex"0000000024002b00000000000000000125002b0000000000000000002600000000000000000000012700000000000000"
        hex"0000000026002b00000000000000000127002b0000000000000000002800000000000000000000012900000000000000"
        hex"0000000028002b00000000000000000129002b000000000000000000";
}

/// @notice The slot map of the program in `spec/launch-program`, from `gen_program_air.py`.
library LaunchSlots {
    /// @notice keccak256 of the transition part the slots were assigned for.
    bytes32 internal constant TAPE_HASH = 0x21dd9f3614d7159308b5fd99bf0f7b294428e807408e7876f423d8543ff2a08f;
    /// @notice Slot cells the program takes: the most computed values live at once.
    uint256 internal constant N_SLOTS = 61;
    /// @notice One byte per op: the slot of the value it writes, 0xff where it writes none.
    bytes internal constant SLOTS =
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0001ff"
        hex"0102ff0203ff0304ff04ff05050000ff01ff02ff03ff04ff05ff00ff06ff070808ff09ff0a0b0bff0cff0d0e0eff0fff"
        hex"101111ff12ff131414ff15ff161717ff18ff191a1aff1bff1c1d1dffff1effff1effff1effff1effff1effff1effff1e"
        hex"ffff1effffffffffffffffffffffffffffffff1fffffffffffffffffffffffffffffffff20ffffffffffffffffffffff"
        hex"ffffffffff21ffffffffffffffffffffffffffffffff22ffffffffffffffffffffffffffffffff23ffffffffffffffff"
        hex"ffffffffffffffff24ffffffffffffffffffffffffffffffff1d1a1aff1a17ff171a1aff17171a1aff1a14ff141a1aff"
        hex"14141a1aff1a11ff111a1aff11111a1aff1a0eff0e1a1aff0e0e1a1aff1a1eff1e1a1aff1e1e2222ff221fff1f2222ff"
        hex"1f1f2323ff2320ff202323ff20202424ff2421ff212424ff21211d1dff01ff02ff03ff04ff05ff00ff20ff21ff1dff06"
        hex"ff09ff0cff0fff12ff15ff18ff1bff07ff0aff0dff10ff13ff16ff19ff1cff1fff1e0e0eff11ff141717ff24ff232222"
        hex"ff1aff0b0808ff25ff262727ff28ff292a2aff2bff2c2d2dff2eff2f3030ffffffffffffffffffffffffffffff31ffff"
        hex"ffffffffffffffffffffffffff32ffffffffffffffffffffffffffffff33ffffffffffffffffffffffffffffff34ffff"
        hex"ffffffffffffffffffffffffff35ffffffffffffffffffffffffffffff36ffffffffffffffffffffffffffffff37ffff"
        hex"ffffffffffffffffffffffffff302d2dff2d2aff2a2d2dff2a2a2d2dff2d27ff272d2dff27272d2dff2d08ff082d2dff"
        hex"08082d2dff2d22ff222d2dff22222d2dff2d31ff312d2dff31313535ff3532ff323535ff32323636ff3633ff333636ff"
        hex"33333737ff3734ff343737ff343430303736363737ff3737373535ff3535352d2dff2d2d2d1717ff171717ff01ff02ff"
        hex"03ff04ff05ff00ff20ff21ff1dff06ff09ff0cff0fff12ff15ff18ff1bff07ff0aff0dff10ff13ff16ff19ff1cff36ff"
        hex"37ff35ff2dff17ff2f2f2c2cff01ff02ff2cff2f2929ff26ff0b2323ff14ff1e2e2eff2bff282525ff1aff241111ff1f"
        hex"ff303434ff33ff323131ff22ff082727ffffffffffffffffffffffffffffff2affffffffffffffffffffffffffffff0e"
        hex"ffffffffffffffffffffffffffffff38ffffffffffffffffffffffffffffff39ffffffffffffffffffffffffffffff3a"
        hex"ffffffffffffffffffffffffffffff3bffffffffffffffffffffffffffffff3cffffffffffffffffffffffffffffff27"
        hex"3131ff3134ff343131ff34343131ff3111ff113131ff11113131ff3125ff253131ff25253131ff312eff2e3131ff2e2e"
        hex"3131ff312aff2a3131ff2a2a3a3aff3a0eff0e3a3aff0e0e3b3bff3b38ff383b3bff38383c3cff3c39ff393c3cff3939"
        hex"2727ff01ff02ff03ff04ff05ff00ff20ff21ff1dff06ff09ff0cff0fff12ff15ff18ff1bff07ff0aff0dff10ff13ff16"
        hex"ff19ff1cff08ff323030ff24ff281e1eff0bff2f2222ff33ff1f1a1aff2bff142626ff2cff273939ff38ff0e2a2aff2e"
        hex"ff251111ffffffffffffffffffffffffffffff34ffffffffffffffffffffffffffffff3cffffffffffffffffffffffff"
        hex"ffffff3bffffffffffffffffffffffffffffff3affffffffffffffffffffffffffffff31ffffffffffffffffffffffff"
        hex"ffffff23ffffffffffffffffffffffffffffff29ffffffffffffffffffffffffffffff112a2aff2a39ff392a2aff3939"
        hex"2a2aff2a26ff262a2aff26262a2aff2a1aff1a2a2aff1a1a2a2aff2a22ff222a2aff22222a2aff2a34ff342a2aff3434"
        hex"3131ff313cff3c3131ff3c3c2323ff233bff3b2323ff3b3b2929ff293aff3a2929ff3a3a11112923232929ff29292931"
        hex"31ff3131312a2aff2a2a2a1e1eff1e1e1eff01ff02ff03ff04ff05ff00ff20ff21ff1dff06ff09ff0cff0fff12ff15ff"
        hex"18ff1bff07ff0aff0dff10ff13ff16ff19ff1cff36ff37ff35ff2dff171e1eff2aff2a31312929ffff232325250e0e27"
        hex"2714141f1f2f2f28283232ff01ff02ff03ff04ff05ff00ff20ff21ff1dff06ff09ff0cff0fff323228ff2f2f2f28ff2f"
        hex"ff01ff02ffff2f322f322f322fff281fff282fff2f321f321f321f1427ff141fff1fff322732273227320e25ff0e32ff"
        hex"32272f272f272f2825ff282fff2fff271f271f271f271425ff1427ff271f321f321f320e25ff0e32ff32ff1f2f1f2f1f"
        hex"2f1f2825ff281fff1f2f272f272f271425ff1427ff272fff2f322f322f322f0e25ff0e2fff2f321f321f321f2825ff28"
        hex"1fff1f32ff322732273227321425ff1432ff32272f272f272f0e25ff0e2fff2f27ff271f271f271f272825ff2827ff27"
        hex"1f321f321f321425ff1432ff32ff1f2f1f2f1f2f1f0e25ff0e1fff1f2f272f272f272825ff2827ff272fff2f322f322f"
        hex"322f1425ff142fff2f321f321f321f0e25ff0e1fff1f3227ff321fff1f0e27ff0e2fff2f0e2f1f320e14ff0e2f1fff2f"
        hex"ff321f321f321f321427ff1432ff321f271f271f272825ff2827ff27ff1f251f251f251f2329ff231fff1f2532253225"
        hex"321429ff1432ff32ff252725272527252829ff2825ff25271f271f271f2329ff231fff1fff273227322732271429ff14"
        hex"27ff273225322532252829ff2825ff25ff321f321f321f322329ff2332ff321f271f271f271429ff1427ff27ff1f251f"
        hex"251f251f2829ff281fff1f2532253225322329ff2332ff32ff252725272527251429ff1425ff25271f271f271f2829ff"
        hex"281fff1fff273227322732272329ff2327ff273225322532251429ff1425ff25ff321f321f321f322829ff2832ff321f"
        hex"271f271f272329ff2327ff271f25ff1f27ff272325ff2332ff322332271f2328ff233227ff32ff1f271f271f271f2825"
        hex"ff281fff1f2725272527251429ff1425ff25ff27292729272927312aff3127ff27291f291f291f282aff281fff1fff29"
        hex"252925292529142aff1429ff29252725272527312aff3127ff27ff251f251f251f25282aff2825ff251f291f291f2914"
        hex"2aff1429ff29ff1f271f271f271f312aff311fff1f272527252725282aff2825ff25ff27292729272927142aff1427ff"
        hex"27291f291f291f312aff311fff1fff29252925292529282aff2829ff29252725272527142aff1427ff27ff251f251f25"
        hex"1f25312aff3125ff251f291f291f29282aff2829ff29ff1f271f271f271f142aff141fff1f272527252725312aff3125"
        hex"ff252729ff2725ff253129ff311fff1f311f25273114ff311f25ff1fff272527252725271429ff1427ff272529252925"
        hex"29282aff2829ff29ff252a252a252a251e2eff1e25ff252a272a272a27142eff1427ff27ff2a292a292a292a282eff28"
        hex"2aff2a2925292529251e2eff1e25ff25ff29272927292729142eff1429ff29272a272a272a282eff282aff2aff272527"
        hex"252725271e2eff1e27ff27252925292529142eff1429ff29ff252a252a252a25282eff2825ff252a272a272a271e2eff"
        hex"1e27ff27ff2a292a292a292a142eff142aff2a292529252925282eff2825ff25ff292729272927291e2eff1e29ff2927"
        hex"2a272a272a142eff142aff2aff27252725272527282eff2827ff272529252925291e2eff1e29ff29252aff2529ff291e"
        hex"2aff1e27ff271e2729251e28ff1e2729ff27";
}
