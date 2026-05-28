// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner — find a CREATE2 salt that yields a hook address with the desired flag bits.
/// @dev Adapted from the standard Uniswap V4 community pattern.
library HookMiner {
    /// @notice The number of low bits in the hook address used as permission flags.
    uint160 internal constant FLAG_MASK = 0x3FFF; // 14 bits

    /// @notice Iterates over salts until it finds one whose CREATE2 address has exactly `flags`
    ///         set in its low 14 bits (every other bit cleared in that window).
    /// @param deployer   The CREATE2 deployer address (usually `address(this)` from a script).
    /// @param flags      The exact 14-bit permission pattern desired.
    /// @param creationCode The contract creationCode (`type(Hook).creationCode`).
    /// @param constructorArgs  ABI-encoded constructor arguments.
    /// @return hookAddress  The address the hook will land at when deployed with `salt`.
    /// @return salt         The mined salt.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 codeHash = keccak256(bytecode);

        for (uint256 i; i < type(uint128).max; ++i) {
            salt = bytes32(i);
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash))))
            );
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: no salt found");
    }
}
