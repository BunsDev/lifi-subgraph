// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ITransactionManager } from "../Interfaces/ITransactionManager.sol";
import { ILiFi } from "../Interfaces/ILiFi.sol";
import { LibAsset } from "../Libraries/LibAsset.sol";
import { LibSwap } from "../Libraries/LibSwap.sol";
import { AppStorage } from "../Libraries/AppStorage.sol";

contract NXTPFacet is ILiFi {
    /* ========== App Storage ========== */

    AppStorage internal s;

    /* ========== Events ========== */

    event NXTPBridgeStarted(
        bytes32 indexed lifiTransactionId,
        bytes32 nxtpTransactionId,
        ITransactionManager.TransactionData txData
    );

    /* ========== Public Bridge Functions ========== */

    /**
     * @notice This function starts a cross-chain transaction using the NXTP protocol
     * @param _lifiData data used purely for tracking and analytics
     * @param _nxtpData data needed to complete an NXTP cross-chain transaction
     */
    function startBridgeTokensViaNXTP(LiFiData memory _lifiData, ITransactionManager.PrepareArgs calldata _nxtpData)
        public
        payable
    {
        // Ensure sender has enough to complete the bridge transaction
        address sendingAssetId = _nxtpData.invariantData.sendingAssetId;
        if (sendingAssetId == address(0)) require(msg.value == _nxtpData.amount, "ERR_INVALID_AMOUNT");
        else {
            uint256 _sendingAssetIdBalance = LibAsset.getOwnBalance(sendingAssetId);
            LibAsset.transferFromERC20(sendingAssetId, msg.sender, address(this), _nxtpData.amount);
            require(
                LibAsset.getOwnBalance(sendingAssetId) - _sendingAssetIdBalance == _nxtpData.amount,
                "ERR_INVALID_AMOUNT"
            );
        }

        // Start the bridge process
        _startBridge(_lifiData.transactionId, _nxtpData);

        emit LiFiTransferStarted(
            _lifiData.transactionId,
            _lifiData.integrator,
            _lifiData.referrer,
            _lifiData.sendingAssetId,
            _lifiData.receivingAssetId,
            _lifiData.receiver,
            _lifiData.amount,
            _lifiData.destinationChainId,
            block.timestamp
        );
    }

    /**
     * @notice This function performs a swap or multiple swaps and then starts a cross-chain transaction
     *         using the NXTP protocol.
     * @param _lifiData data used purely for tracking and analytics
     * @param _swapData array of data needed for swaps
     * @param _nxtpData data needed to complete an NXTP cross-chain transaction
     */
    function swapAndStartBridgeTokensViaNXTP(
        LiFiData memory _lifiData,
        LibSwap.SwapData[] calldata _swapData,
        ITransactionManager.PrepareArgs calldata _nxtpData
    ) public payable {
        address sendingAssetId = _nxtpData.invariantData.sendingAssetId;
        uint256 _sendingAssetIdBalance = LibAsset.getOwnBalance(sendingAssetId);

        // Swap
        for (uint8 i; i < _swapData.length; i++) {
            LibSwap.swap(_lifiData.transactionId, _swapData[i]);
        }

        require(
            LibAsset.getOwnBalance(sendingAssetId) - _sendingAssetIdBalance >= _nxtpData.amount,
            "ERR_INVALID_AMOUNT"
        );

        _startBridge(_lifiData.transactionId, _nxtpData);

        emit LiFiTransferStarted(
            _lifiData.transactionId,
            _lifiData.integrator,
            _lifiData.referrer,
            _lifiData.sendingAssetId,
            _lifiData.receivingAssetId,
            _lifiData.receiver,
            _lifiData.amount,
            _lifiData.destinationChainId,
            block.timestamp
        );
    }

    /**
     * @notice Completes a cross-chain transaction on the receiving chain using the NXTP protocol.
     * @param _lifiData data used purely for tracking and analytics
     * @param assetId token received on the receiving chain
     * @param receiver address that will receive the tokens
     * @param amount number of tokens received
     */
    function completeBridgeTokensViaNXTP(
        LiFiData memory _lifiData,
        address assetId,
        address receiver,
        uint256 amount
    ) public payable {
        if (LibAsset.isNativeAsset(assetId)) {
            require(msg.value == amount, "INVALID_ETH_AMOUNT");
        } else {
            require(msg.value == 0, "ETH_WITH_ERC");
            LibAsset.transferFromERC20(assetId, msg.sender, address(this), amount);
        }

        LibAsset.transferAsset(assetId, payable(receiver), amount);

        emit LiFiTransferCompleted(_lifiData.transactionId, assetId, receiver, amount, block.timestamp);
    }

    /**
     * @notice Performs a swap before completing a cross-chain transaction
     *         on the receiving chain using the NXTP protocol.
     * @param _lifiData data used purely for tracking and analytics
     * @param _swapData array of data needed for swaps
     * @param finalAssetId token received on the receiving chain
     * @param receiver address that will receive the tokens
     */
    function swapAndCompleteBridgeTokensViaNXTP(
        LiFiData memory _lifiData,
        LibSwap.SwapData[] calldata _swapData,
        address finalAssetId,
        address receiver
    ) public payable {
        uint256 startingBalance = LibAsset.getOwnBalance(finalAssetId);

        // Swap
        for (uint8 i; i < _swapData.length; i++) {
            LibSwap.swap(_lifiData.transactionId, _swapData[i]);
        }

        uint256 postSwapBalance = LibAsset.getOwnBalance(finalAssetId);

        uint256 finalBalance;

        if (postSwapBalance > startingBalance) {
            finalBalance = postSwapBalance - startingBalance;
            LibAsset.transferAsset(finalAssetId, payable(receiver), finalBalance);
        }

        emit LiFiTransferCompleted(_lifiData.transactionId, finalAssetId, receiver, finalBalance, block.timestamp);
    }

    /* ========== Internal Functions ========== */

    function _startBridge(bytes32 _transactionId, ITransactionManager.PrepareArgs calldata _nxtpData) internal {
        IERC20 sendingAssetId = IERC20(_nxtpData.invariantData.sendingAssetId);

        // Give Connext approval to bridge tokens
        LibAsset.approveERC20(IERC20(sendingAssetId), address(s.nxtpTxManager), _nxtpData.amount);

        uint256 value = LibAsset.isNativeAsset(address(sendingAssetId)) ? msg.value : 0;

        // Initiate bridge transaction on sending chain
        ITransactionManager.TransactionData memory result = s.nxtpTxManager.prepare{ value: value }(_nxtpData);

        emit NXTPBridgeStarted(_transactionId, result.transactionId, result);
    }

    /* ========== Getter Functions ========== */

    /**
     * @notice show the NXTP transaction manager contract address
     */
    function getNXTPTransactionManager() external view returns (address) {
        return address(s.nxtpTxManager);
    }
}
