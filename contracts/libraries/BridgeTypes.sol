// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title BridgeTypes
/// @notice Defines bridge types
library BridgeTypes {
    // Bridge type identifiers (1 byte)
    uint8 constant HYP_XERC20 = 0x01;
    uint8 constant XVELO = 0x02;
    /// @dev HYP_ERC20_COLLATERAL handles both HypERC20Collateral and HypNative; the native
    /// path is selected when the caller passes `token == address(0)`.
    uint8 constant HYP_ERC20_COLLATERAL = 0x03;
    // Future bridge types can be added here
}
