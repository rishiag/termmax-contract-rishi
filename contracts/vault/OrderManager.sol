// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PendingLib, PendingAddress, PendingUint192} from "contracts/lib/PendingLib.sol";
import {ITermMaxMarket} from "contracts/ITermMaxMarket.sol";
import {CurveCuts} from "contracts/storage/TermMaxStorage.sol";
import {VaultErrors} from "contracts/errors/VaultErrors.sol";
import {VaultEvents} from "contracts/events/VaultEvents.sol";
import {ITermMaxRouter} from "contracts/router/ITermMaxRouter.sol";
import {ITermMaxOrder} from "contracts/ITermMaxOrder.sol";
import {VaultConstants} from "contracts/lib/VaultConstants.sol";
import {TransferUtils} from "contracts/lib/TransferUtils.sol";
import {Constants} from "contracts/lib/Constants.sol";
import {ArrayUtils} from "contracts/lib/ArrayUtils.sol";
import {OrderConfig, CurveCuts} from "contracts/storage/TermMaxStorage.sol";
import {MathLib} from "contracts/lib/MathLib.sol";
import {IOrderManager} from "./IOrderManager.sol";
import {ISwapCallback} from "contracts/ISwapCallback.sol";
import {OrderInfo, VaultStorage} from "./VaultStorage.sol";
/**
 * @title Order Manager
 * @author Term Structure Labs
 * @notice The extension of the TermMaxVault that manages orders and calculates interest
 */

contract OrderManager is VaultErrors, VaultEvents, VaultStorage, IOrderManager {
    using SafeCast for uint256;
    using SafeCast for int256;
    using TransferUtils for IERC20;
    using ArrayUtils for address[];
    using MathLib for uint256;

    address private immutable ORDER_MANAGER_SINGLETON;

    /**
     * @notice Reverts if the caller is not the proxy
     */
    modifier onlyProxy() {
        if (address(this) == ORDER_MANAGER_SINGLETON) revert OnlyProxy();
        _;
    }

    constructor() {
        ORDER_MANAGER_SINGLETON = address(this);
    }

    /**
     * @inheritdoc IOrderManager
     */
    function updateOrders(
        IERC20 asset,
        ITermMaxOrder[] memory orders,
        int256[] memory changes,
        uint256[] memory maxSupplies,
        CurveCuts[] memory curveCuts
    ) external override onlyProxy {
        _accruedInterest();
        for (uint256 i = 0; i < orders.length; ++i) {
            _updateOrder(asset, ITermMaxOrder(orders[i]), changes[i], maxSupplies[i], curveCuts[i]);
        }
    }

    /**
     * @inheritdoc IOrderManager
     */
    function withdrawPerformanceFee(IERC20 asset, address recipient, uint256 amount) external override onlyProxy {
        _accruedInterest();
        _withdrawPerformanceFee(asset, recipient, amount);
    }

    /**
     * @inheritdoc IOrderManager
     */
    function redeemOrder(ITermMaxOrder order) external override onlyProxy {
        _redeemFromMarket(address(order), _orderMapping[address(order)]);
    }

    /**
     * @inheritdoc IOrderManager
     */
    function createOrder(
        IERC20 asset,
        ITermMaxMarket market,
        uint256 maxSupply,
        uint256 initialReserve,
        CurveCuts memory curveCuts
    ) external onlyProxy returns (ITermMaxOrder order) {
        if (
            _supplyQueue.length + 1 >= VaultConstants.MAX_QUEUE_LENGTH
                || _withdrawQueue.length + 1 >= VaultConstants.MAX_QUEUE_LENGTH
        ) revert MaxQueueLengthExceeded();

        (IERC20 ft, IERC20 xt,,, IERC20 debtToken) = market.tokens();
        if (asset != debtToken) revert InconsistentAsset();

        order = market.createOrder(address(this), maxSupply, ISwapCallback(address(this)), curveCuts);
        if (initialReserve > 0) {
            asset.safeIncreaseAllowance(address(market), initialReserve);
            market.mint(address(order), initialReserve);
        }
        _supplyQueue.push(address(order));
        _withdrawQueue.push(address(order));

        uint64 orderMaturity = market.config().maturity;
        _orderMapping[address(order)] =
            OrderInfo({market: market, ft: ft, xt: xt, maxSupply: maxSupply.toUint128(), maturity: orderMaturity});
        _insertMaturity(orderMaturity);

        emit CreateOrder(msg.sender, address(market), address(order), maxSupply, initialReserve, curveCuts);
    }

    /**
     * @notice Insert a maturity into the maturity linked list
     * @param maturity The maturity to insert
     */
    function _insertMaturity(uint64 maturity) internal {
        uint64 priorMaturity = _recentestMaturity;
        if (_recentestMaturity == 0) {
            _recentestMaturity = maturity;
            return;
        } else if (maturity < priorMaturity) {
            _recentestMaturity = maturity;
            _maturityMapping[maturity] = priorMaturity;
            return;
        }

        uint64 nextMaturity = _maturityMapping[priorMaturity];
        while (nextMaturity > 0) {
            if (maturity < nextMaturity) {
                _maturityMapping[maturity] = nextMaturity;
                if (priorMaturity > 0) _maturityMapping[priorMaturity] = maturity;
                return;
            } else if (maturity == nextMaturity) {
                break;
            } else {
                priorMaturity = nextMaturity;
                nextMaturity = _maturityMapping[priorMaturity];
            }
        }
        _maturityMapping[priorMaturity] = maturity;
    }

    function _updateOrder(
        IERC20 asset,
        ITermMaxOrder order,
        int256 changes,
        uint256 maxSupply,
        CurveCuts memory curveCuts
    ) internal {
        _checkOrder(address(order));
        OrderInfo memory orderInfo = _orderMapping[address(order)];
        orderInfo.maxSupply = maxSupply.toUint128();
        OrderConfig memory newOrderConfig;
        newOrderConfig.curveCuts = curveCuts;
        newOrderConfig.maxXtReserve = maxSupply;
        newOrderConfig.swapTrigger = ISwapCallback(address(this));
        if (changes < 0) {
            // withdraw assets from order and burn to assets
            order.updateOrder(newOrderConfig, changes, changes);
            uint256 withdrawChanges = (-changes).toUint256();
            orderInfo.ft.safeIncreaseAllowance(address(orderInfo.market), withdrawChanges);
            orderInfo.xt.safeIncreaseAllowance(address(orderInfo.market), withdrawChanges);
            orderInfo.market.burn(address(this), withdrawChanges);
        } else {
            // deposit assets to order
            uint256 depositChanges = changes.toUint256();
            asset.safeIncreaseAllowance(address(orderInfo.market), depositChanges);
            orderInfo.market.mint(address(order), depositChanges);
            changes = 0;

            order.updateOrder(newOrderConfig, changes, changes);
        }
        _orderMapping[address(order)] = orderInfo;
        emit UpdateOrder(msg.sender, address(order), changes, maxSupply, curveCuts);
    }

    /**
     * @inheritdoc IOrderManager
     */
    function depositAssets(IERC20 asset, uint256 amount) external override onlyProxy {
        _accruedInterest();
        uint256 amountLeft = amount;
        for (uint256 i = 0; i < _supplyQueue.length; ++i) {
            address order = _supplyQueue[i];

            //check maturity
            OrderInfo memory orderInfo = _orderMapping[order];
            if (block.timestamp > orderInfo.maturity) continue;

            //check supply
            uint256 xtReserve = orderInfo.xt.balanceOf(order);
            if (xtReserve >= orderInfo.maxSupply) continue;

            uint256 depositAmt = (orderInfo.maxSupply - xtReserve).min(amountLeft);

            asset.safeIncreaseAllowance(address(orderInfo.market), depositAmt);
            orderInfo.market.mint(order, depositAmt);
            amountLeft -= depositAmt;
            if (amountLeft == 0) break;
        }
        // deposit to lpers
        _totalFt += amount;
        _accretingPrincipal += amount;
    }

    /**
     * @inheritdoc IOrderManager
     */
    function withdrawAssets(IERC20 asset, address recipient, uint256 amount) external override onlyProxy {
        _accruedInterest();
        uint256 amountLeft = amount;
        uint256 assetBalance = asset.balanceOf(address(this));
        if (assetBalance >= amount) {
            asset.safeTransfer(recipient, amount);
            _totalFt -= amount;
            _accretingPrincipal -= amount;
        } else {
            amountLeft -= assetBalance;
            uint256 length = _withdrawQueue.length;
            // withdraw from orders
            uint256 i;
            while (length > 0 && i < length) {
                address order = _withdrawQueue[i];
                OrderInfo memory orderInfo = _orderMapping[order];
                if (block.timestamp > orderInfo.maturity + Constants.LIQUIDATION_WINDOW) {
                    // redeem assets from expired order
                    uint256 totalRedeem = _redeemFromMarket(order, orderInfo);
                    length--;
                    if (totalRedeem < amountLeft) {
                        amountLeft -= totalRedeem;
                        continue;
                    } else {
                        asset.safeTransfer(recipient, amountLeft);
                        amountLeft = 0;
                        break;
                    }
                } else if (block.timestamp < orderInfo.maturity) {
                    // withraw ft and xt from order to burn
                    uint256 maxWithdraw = orderInfo.xt.balanceOf(order).min(orderInfo.ft.balanceOf(order));

                    if (maxWithdraw < amountLeft) {
                        amountLeft -= maxWithdraw;
                        _burnFromOrder(ITermMaxOrder(order), orderInfo, maxWithdraw);
                        ++i;
                    } else {
                        _burnFromOrder(ITermMaxOrder(order), orderInfo, amountLeft);
                        asset.safeTransfer(recipient, amountLeft);
                        amountLeft = 0;
                        break;
                    }
                } else {
                    // ignore orders that are in liquidation window
                    ++i;
                }
            }
            if (amountLeft > 0) {
                uint256 maxWithdraw = amount - amountLeft;
                revert InsufficientFunds(maxWithdraw, amount);
            }
        }

        _totalFt -= amount;
        _accretingPrincipal -= amount;
    }

    function _withdrawPerformanceFee(IERC20 asset, address recipient, uint256 amount) internal {
        if (amount > _performanceFee) revert InsufficientFunds(_performanceFee, amount);
        asset.safeTransfer(recipient, amount);
        _performanceFee -= amount;
        _totalFt -= amount;

        emit WithdrawPerformanceFee(msg.sender, recipient, amount);
    }

    /**
     * @inheritdoc IOrderManager
     */
    function dealBadDebt(address recipient, address collaretal, uint256 amount)
        external
        onlyProxy
        returns (uint256 collateralOut)
    {
        _accruedInterest();
        uint256 badDebtAmt = _badDebtMapping[collaretal];
        if (badDebtAmt == 0) revert NoBadDebt(collaretal);
        if (amount > badDebtAmt) revert InsufficientFunds(badDebtAmt, amount);
        uint256 collateralBalance = IERC20(collaretal).balanceOf(address(this));
        collateralOut = (amount * collateralBalance) / badDebtAmt;
        IERC20(collaretal).safeTransfer(recipient, collateralOut);
        _badDebtMapping[collaretal] -= amount;
        _accretingPrincipal -= amount;
        _totalFt -= amount;
    }

    function _burnFromOrder(ITermMaxOrder order, OrderInfo memory orderInfo, uint256 amount) internal {
        order.withdrawAssets(orderInfo.ft, address(this), amount);
        order.withdrawAssets(orderInfo.xt, address(this), amount);
        orderInfo.ft.safeIncreaseAllowance(address(orderInfo.market), amount);
        orderInfo.xt.safeIncreaseAllowance(address(orderInfo.market), amount);

        orderInfo.market.burn(address(this), amount);
    }

    function _redeemFromMarket(address order, OrderInfo memory orderInfo) internal returns (uint256 totalRedeem) {
        uint256 ftReserve = orderInfo.ft.balanceOf(order);
        ITermMaxOrder(order).withdrawAssets(orderInfo.ft, address(this), ftReserve);
        orderInfo.ft.safeIncreaseAllowance(address(orderInfo.market), ftReserve);
        totalRedeem = orderInfo.market.redeem(ftReserve, address(this));
        if (totalRedeem < ftReserve) {
            // storage bad debt
            (,,, address collateral,) = orderInfo.market.tokens();
            _badDebtMapping[collateral] = ftReserve - totalRedeem;
        }
        emit RedeemOrder(msg.sender, order, ftReserve.toUint128(), totalRedeem.toUint128());

        delete _orderMapping[order];
        _supplyQueue.remove(_supplyQueue.indexOf(order));
        _withdrawQueue.remove(_withdrawQueue.indexOf(order));
    }

    /// @notice Calculate and distribute accrued the interest from start to end time
    function _accruedPeriodInterest(uint256 startTime, uint256 endTime) internal {
        uint256 interest = (_annualizedInterest * (endTime - startTime)) / 365 days;
        uint256 _performanceFeeToCurator = (interest * _performanceFeeRate) / Constants.DECIMAL_BASE;
        // accrue interest
        _performanceFee += _performanceFeeToCurator;
        _accretingPrincipal += (interest - _performanceFeeToCurator);
    }

    /// @notice Distribute interest
    function _accruedInterest() internal {
        uint64 currentTime = block.timestamp.toUint64();

        uint256 lastTime = _lastUpdateTime;
        uint64 recentMaturity = _recentestMaturity;
        if (lastTime == 0) {
            lastTime = currentTime;
        }
        while (currentTime >= recentMaturity && recentMaturity != 0) {
            _accruedPeriodInterest(lastTime, recentMaturity);
            lastTime = recentMaturity;
            uint64 nextMaturity = _maturityMapping[recentMaturity];
            delete _maturityMapping[recentMaturity];
            // update anualized interest
            _annualizedInterest -= _maturityToInterest[recentMaturity];
            delete _maturityToInterest[recentMaturity];
            recentMaturity = nextMaturity;
        }
        if (recentMaturity > 0) {
            _accruedPeriodInterest(lastTime, currentTime);
            _recentestMaturity = recentMaturity;
        } else {
            // all orders are expired
            _recentestMaturity = 0;
            _annualizedInterest = 0;
        }
        _lastUpdateTime = currentTime;
    }

    function _checkLockedFt() internal view {
        if (_accretingPrincipal + _performanceFee > _totalFt) revert LockedFtGreaterThanTotalFt();
    }

    function _checkOrder(address orderAddress) internal view {
        if (address(_orderMapping[orderAddress].market) == address(0)) {
            revert UnauthorizedOrder(orderAddress);
        }
    }

    /// @notice Callback function for the swap
    /// @param deltaFt The change in the ft balance of the order
    function swapCallback(int256 deltaFt) external onlyProxy {
        address orderAddress = msg.sender;
        /// @dev Check if the order is valid
        _checkOrder(orderAddress);
        uint64 maturity = _orderMapping[orderAddress].maturity;
        /// @dev Calculate interest from last update time to now
        _accruedInterest();

        /// @dev If ft increases, interest increases, and if ft decreases,
        ///  interest decreases. Update the expected annualized return based on the change
        uint256 ftChanges;

        if (deltaFt > 0) {
            ftChanges = deltaFt.toUint256();
            _totalFt += ftChanges;
            uint256 deltaAnualizedInterest = (ftChanges * Constants.DAYS_IN_YEAR) / _daysToMaturity(maturity);

            _maturityToInterest[maturity] += deltaAnualizedInterest.toUint128();

            _annualizedInterest += deltaAnualizedInterest;
        } else {
            ftChanges = (-deltaFt).toUint256();
            _totalFt -= ftChanges;
            uint256 deltaAnualizedInterest = (ftChanges * Constants.DAYS_IN_YEAR) / _daysToMaturity(maturity);
            if (_maturityToInterest[maturity] < deltaAnualizedInterest || _annualizedInterest < deltaAnualizedInterest)
            {
                revert LockedFtGreaterThanTotalFt();
            }
            _maturityToInterest[maturity] -= deltaAnualizedInterest.toUint128();
            _annualizedInterest -= deltaAnualizedInterest;
        }
        /// @dev Ensure that the total assets after the transaction are
        ///greater than or equal to the principal and the allocated interest
        _checkLockedFt();
    }

    /// @notice Calculate how many days until expiration
    function _daysToMaturity(uint256 maturity) internal view returns (uint256 daysToMaturity) {
        daysToMaturity = (maturity - block.timestamp + Constants.SECONDS_IN_DAY - 1) / Constants.SECONDS_IN_DAY;
    }
}
