// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookDeployer
/// @notice CREATE2 salt mining for Uniswap v4 hooks, the way the launch deployer places them.
/// @dev Internal only, so callers inline it. Used by the deploy script and the tests; not launched.
library HookDeployer {
    error NoSaltFound();
    error HookDeploymentFailed();

    /// @notice The address CREATE2 would give `creationCode` from `deployer` with `salt`.
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Finds a salt under which `deployer` lands `creationCode` on an address carrying exactly `flags`
    /// and no code yet.
    function mine(address deployer, bytes memory creationCode, uint160 flags, uint256 maxTries)
        internal
        view
        returns (bytes32 salt, address hook)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < maxTries; i++) {
            address predicted = predict(deployer, bytes32(i), initCodeHash);
            if (HookFlags.matches(predicted, flags) && predicted.code.length == 0) return (bytes32(i), predicted);
        }
        revert NoSaltFound();
    }

    /// @notice Deploys `creationCode` with CREATE2 from the calling contract at an address carrying `flags`.
    function deploy(bytes memory creationCode, uint160 flags) internal returns (address hook) {
        (bytes32 salt, address predicted) = mine(address(this), creationCode, flags, 500_000);
        assembly ("memory-safe") {
            hook := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (hook == address(0) || hook != predicted) revert HookDeploymentFailed();
    }
}
