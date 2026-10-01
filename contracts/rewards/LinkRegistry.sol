// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title LinkRegistry
/// @notice Links a mainnet address, which holds or locks NOX, to one testnet address, which takes part in
///         the Shield testnet. The testnet rewards programme counts a mainnet stake for the testnet address
///         it is linked to, so one stake is never counted for two testnet addresses, and one testnet
///         address never carries two stakes.
/// @dev Lives on the testnet. No owner. Both sides consent: the mainnet address signs the link (EIP-712,
///      domain on chain id 1, the chain its wallet is connected to), and the testnet address sends it.
///      A plain account's signature is checked here. A contract wallet's (ERC-1271) can only be checked on
///      mainnet, where the wallet lives, so it is stored and the reward script checks it there at the
///      epoch's first block; until then the link is recorded but counts for nothing.
///      A link, or a change of link, takes effect from the next epoch, and each mainnet address may
///      change its link at most once per epoch. Before genesis a link counts from epoch 0, and may be
///      changed freely.
contract LinkRegistry {
    /// @notice Epoch 0 starts here: 1 October 2026 00:00 UTC for the programme.
    uint256 public immutable genesis;
    uint256 public constant EPOCH = 7 days;
    uint256 public constant MAINNET_CHAIN_ID = 1;

    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId)");
    bytes32 public constant LINK_TYPEHASH = keccak256("Link(address mainnet,address testnet,uint256 nonce)");
    /// @notice The domain a mainnet wallet signs under.
    bytes32 public immutable domainSeparator;

    struct Link {
        address testnet;
        uint64 fromEpoch; // the first epoch the link counts in
        uint64 changedInEpoch; // the epoch of the last change, for the once-per-epoch rule
        bool contractWallet; // the signature is ERC-1271, checked on mainnet by the reward script
    }

    mapping(address mainnet => Link) internal _links;
    /// @notice The mainnet address a testnet address is linked to, or zero.
    mapping(address testnet => address mainnet) public mainnetOf;
    /// @notice The next nonce each mainnet address signs.
    mapping(address mainnet => uint256) public nonces;

    event Linked(
        address indexed mainnet, address indexed testnet, uint64 fromEpoch, bool contractWallet, bytes signature
    );
    event Unlinked(address indexed mainnet, address indexed testnet, uint64 fromEpoch);

    error ZeroAddress();
    error TestnetTaken(address mainnet);
    error AlreadyChangedThisEpoch(uint64 epoch);
    error BadSignature();
    error NotLinked();

    constructor(uint256 genesis_) {
        genesis = genesis_;
        domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NOX testnet rewards"), keccak256("1"), MAINNET_CHAIN_ID)
        );
    }

    /// @notice Links `mainnet` to the caller. `signature` is the mainnet address's signature over
    ///         Link(mainnet, caller, nonces[mainnet]). Set `contractWallet` for an ERC-1271 wallet.
    function link(address mainnet, bytes calldata signature, bool contractWallet) external {
        if (mainnet == address(0)) revert ZeroAddress();
        (bool started, uint64 e) = _epoch();
        uint64 from = started ? e + 1 : 0;
        address current = mainnetOf[msg.sender];
        if (current != address(0) && current != mainnet) revert TestnetTaken(current);

        Link storage l = _links[mainnet];
        // a mainnet address that has ever linked changes at most once per epoch, unlinks included
        if (started && nonces[mainnet] != 0 && l.changedInEpoch == e) revert AlreadyChangedThisEpoch(e);

        bytes32 digest = linkDigest(mainnet, msg.sender, nonces[mainnet]);
        if (!contractWallet) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
            if (err != ECDSA.RecoverError.NoError || signer != mainnet) revert BadSignature();
        }
        unchecked {
            ++nonces[mainnet];
        }

        if (l.testnet != address(0) && l.testnet != msg.sender) {
            delete mainnetOf[l.testnet];
            emit Unlinked(mainnet, l.testnet, from);
        }
        l.testnet = msg.sender;
        l.fromEpoch = from;
        l.changedInEpoch = started ? e : type(uint64).max;
        l.contractWallet = contractWallet;
        mainnetOf[msg.sender] = mainnet;
        emit Linked(mainnet, msg.sender, from, contractWallet, signature);
    }

    /// @notice Ends the caller's link from the next epoch. The testnet side may always leave.
    function unlink() external {
        address mainnet = mainnetOf[msg.sender];
        if (mainnet == address(0)) revert NotLinked();
        (bool started, uint64 e) = _epoch();
        delete mainnetOf[msg.sender];
        Link storage l = _links[mainnet];
        l.testnet = address(0);
        l.changedInEpoch = started ? e : type(uint64).max;
        emit Unlinked(mainnet, msg.sender, started ? e + 1 : 0);
    }

    /// @notice The EIP-712 digest the mainnet address signs.
    function linkDigest(address mainnet, address testnet, uint256 nonce) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", domainSeparator, keccak256(abi.encode(LINK_TYPEHASH, mainnet, testnet, nonce))
            )
        );
    }

    /// @notice The programme's epoch now, and whether the programme has started. Epoch 0 before genesis.
    function currentEpoch() external view returns (bool started, uint64 epoch) {
        return _epoch();
    }

    function _epoch() private view returns (bool started, uint64 e) {
        if (block.timestamp < genesis) return (false, 0);
        return (true, uint64((block.timestamp - genesis) / EPOCH));
    }

    /// @notice The link of a mainnet address.
    function linkOf(address mainnet) external view returns (Link memory) {
        return _links[mainnet];
    }
}
