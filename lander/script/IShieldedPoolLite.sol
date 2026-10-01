// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The part of the pool's ABI the relayer's settle script calls. The relayer kit compiles this
///         instead of the pool's source, so it builds in seconds and carries no verifier code.
/// @dev Must match contracts/shield/ShieldedPool.sol: the ResidualExec field order and settleBatch's
///      argument list are part of the function selector.
interface IShieldedPoolLite {
    struct ResidualExec {
        address router;
        uint64 assetIn;
        uint64 assetOut;
        uint256 amountIn;
        uint256 amountOutMin;
        address[] path;
        uint256 deadline;
    }

    function settleBatch(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        ResidualExec calldata residual,
        bytes calldata attestation,
        bytes[] calldata encryptedNotes
    ) external;

    function verifier() external view returns (address);
    function associationRegistry() external view returns (address);
    function nextLeafIndex() external view returns (uint40);
}

interface IStarkVerifierLite {
    function verifyBatch(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool ok);
}

interface IAssociationSetRegistryLite {
    function isRegisteredRoot(bytes32 root) external view returns (bool);
}
