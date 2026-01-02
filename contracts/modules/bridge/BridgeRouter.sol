// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';
import {HypXERC20} from '@hyperlane/core/contracts/token/extensions/HypXERC20.sol';
import {StandardHookMetadata} from '@hyperlane/core/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

import {ITokenBridge} from '../../interfaces/external/ITokenBridge.sol';
import {BridgeTypes} from '../../libraries/BridgeTypes.sol';
import {Permit2Payments} from './../Permit2Payments.sol';

/// @title BridgeRouter
/// @notice Handles cross-chain bridging operations
abstract contract BridgeRouter is Permit2Payments {
    using SafeTransferLib for ERC20;

    error InvalidTokenAddress();
    error InvalidRecipient();

    /// @notice Send tokens x-chain using the selected bridge
    /// @param sender The address initiating the bridge
    /// @param recipient The recipient address on the destination chain
    /// @param bridge The bridge used for the token
    /// @param amount The amount to bridge
    /// @param tokenFee The fee to pay for token bridging
    /// @param domain The destination domain
    /// @param payer The address to pay for the transfer
    function bridgeToken(
        address sender,
        address recipient,
        address bridge,
        uint256 amount,
        uint256 tokenFee,
        uint32 domain,
        address payer
    ) internal {
        if (recipient == address(0)) revert InvalidRecipient();

        address token = ITokenBridge(bridge).token();

        prepareTokensForBridge({_token: token, _bridge: bridge, _payer: payer, _amount: tokenFee});

        ITokenBridge(bridge).transferRemote({
            destination: domain,
            recipient: recipient,
            amount: amount
        });
    }

    /// @dev Moves the tokens from sender to this contract then approves the bridge
    function prepareTokensForBridge(address _token, address _bridge, address _payer, uint256 _amount) private {
        if (_payer != address(this)) {
            payOrPermit2Transfer({token: _token, payer: _payer, recipient: address(this), amount: _amount});
        }
        ERC20(_token).safeApprove({to: _bridge, amount: _amount});
    }
}
