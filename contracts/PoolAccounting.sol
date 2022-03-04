// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IEToken.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IPoolAccounting.sol";
import "./interfaces/IFixedLender.sol";
import "./utils/TSUtils.sol";
import "./utils/DecimalMath.sol";
import "./utils/Errors.sol";

contract PoolAccounting is IPoolAccounting, AccessControl {
    using PoolLib for PoolLib.MaturityPool;
    using PoolLib for PoolLib.Position;
    using DecimalMath for uint256;

    // Vars used in `borrowMP` to avoid
    // stack too deep problem
    struct BorrowVars {
        PoolLib.Position position;
        uint256 feeRate;
        uint256 fee;
    }

    // Vars used in `repayMP` to avoid
    // stack too deep problem
    struct RepayVars {
        PoolLib.Position position;
        PoolLib.Position scaleDebtCovered;
        uint256 amountOwed;
        uint256 penalties;
        uint256 discountFee;
        uint256 feeSP;
        uint256 amountStillBorrowed;
        uint256 smartPoolDebtReduction;
    }

    mapping(uint256 => mapping(address => PoolLib.Position))
        public mpUserSuppliedAmount;
    mapping(uint256 => mapping(address => PoolLib.Position))
        public mpUserBorrowedAmount;

    mapping(address => uint256[]) public userMpBorrowed;
    mapping(uint256 => PoolLib.MaturityPool) public maturityPools;
    uint256 public override smartPoolBorrowed;

    address private fixedLenderAddress;
    IInterestRateModel public interestRateModel;

    event Initialized(address indexed fixedLender);

    /**
     * @dev modifier used to allow calls to certain functions only from
     * the `fixedLender` contract. `fixedLenderAddress` should be set
     * through `initialize` method
     */
    modifier onlyFixedLender() {
        if (msg.sender != address(fixedLenderAddress)) {
            revert GenericError(ErrorCode.CALLER_MUST_BE_FIXED_LENDER);
        }
        _;
    }

    constructor(address _interestRateModelAddress) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        interestRateModel = IInterestRateModel(_interestRateModelAddress);
    }

    /**
     * @dev Initializes the PoolAccounting setting the FixedLender address
     * - Only able to initialize once
     * @param _fixedLenderAddress The address of the FixedLender that uses this PoolAccounting
     */
    function initialize(address _fixedLenderAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (fixedLenderAddress != address(0)) {
            revert GenericError(ErrorCode.CONTRACT_ALREADY_INITIALIZED);
        }

        fixedLenderAddress = _fixedLenderAddress;

        emit Initialized(_fixedLenderAddress);
    }

    /**
     * @dev Function to account for borrowing money from a maturity pool (MP).
     *      It doesn't check liquidity for the borrower, so the `fixedLender`
     *      should call `validateBorrowMP` immediately after calling this function.
     * @param maturityDate maturity date / pool id where the asset will be borrowed
     * @param borrower borrower that it will take the debt
     * @param amount amount that the borrower will be borrowing
     * @param maxAmountAllowed maximum amount that the borrower is willing to pay
     *        at maturity
     * @param maxSPDebt maximum amount of assset debt that the MP can have with the SP
     * @return totalOwedNewBorrow : total amount that will need to be paid at maturity for this borrow
     */
    function borrowMP(
        uint256 maturityDate,
        address borrower,
        uint256 amount,
        uint256 maxAmountAllowed,
        uint256 maxSPDebt
    )
        external
        override
        onlyFixedLender
        returns (
            uint256 totalOwedNewBorrow,
            uint256 earningsSP,
            uint256 earningsTreasury
        )
    {
        BorrowVars memory borrowVars;

        PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

        earningsSP += pool.accrueEarnings(maturityDate, currentTimestamp());
        smartPoolBorrowed += pool.borrowMoney(amount, maxSPDebt);

        borrowVars.feeRate = interestRateModel.getRateToBorrow(
            maturityDate,
            block.timestamp,
            pool.borrowed,
            pool.supplied,
            maxSPDebt
        );
        borrowVars.fee = amount.mul_(borrowVars.feeRate);
        totalOwedNewBorrow = amount + borrowVars.fee;

        // We validate that the user is not taking arbitrary fees
        if (totalOwedNewBorrow > maxAmountAllowed) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        // If used doesn't have a current position, we add it to the list
        // of all of them
        borrowVars.position = mpUserBorrowedAmount[maturityDate][borrower];
        if (borrowVars.position.principal == 0) {
            userMpBorrowed[borrower].push(maturityDate);
        }

        // We distribute to treasury and also to unassigned
        uint256 unassignedEarnings;
        (unassignedEarnings, earningsTreasury) = PoolLib.distributeAccordingly(
            borrowVars.fee,
            pool.suppliedSP,
            amount
        );
        pool.addFee(unassignedEarnings);

        mpUserBorrowedAmount[maturityDate][borrower] = PoolLib.Position(
            borrowVars.position.principal + amount,
            borrowVars.position.fee + borrowVars.fee
        );
    }

    /**
     * @dev Function to account for a deposit to a maturity pool (MP). It doesn't transfer or
     * @param maturityDate maturity date / pool id where the asset will be deposited
     * @param supplier address that will be depositing the assets
     * @param amount amount that the supplier will be depositing
     * @param minAmountRequired minimum amount that the borrower is expecting to receive at
     *        maturity
     * @return currentTotalDeposit : the amount that should be collected at maturity for this deposit
     */
    function depositMP(
        uint256 maturityDate,
        address supplier,
        uint256 amount,
        uint256 minAmountRequired
    )
        external
        override
        onlyFixedLender
        returns (uint256 currentTotalDeposit, uint256 earningsSP)
    {
        earningsSP = maturityPools[maturityDate].accrueEarnings(
            maturityDate,
            currentTimestamp()
        );

        (uint256 fee, uint256 feeSP) = interestRateModel.getYieldForDeposit(
            maturityPools[maturityDate].suppliedSP,
            maturityPools[maturityDate].earningsUnassigned,
            amount
        );

        currentTotalDeposit = amount + fee;
        if (currentTotalDeposit < minAmountRequired) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        smartPoolBorrowed -= maturityPools[maturityDate].depositMoney(amount);
        maturityPools[maturityDate].removeFee(fee + feeSP);
        earningsSP += feeSP;

        // We update users's position
        PoolLib.Position memory position = mpUserSuppliedAmount[maturityDate][
            supplier
        ];
        mpUserSuppliedAmount[maturityDate][supplier] = PoolLib.Position(
            position.principal + amount,
            position.fee + fee
        );
    }

    /**
     * @dev Function to account for a withdraw from a maturity pool (MP).
     * @param maturityDate maturity date / pool id where the asset should be accounted for
     * @param redeemer address that should have the assets withdrawn
     * @param amount amount that the redeemer will be extracting
     * @param maxSPDebt max amount of debt that can be taken from the SP in case of illiquidity
     */
    function withdrawMP(
        uint256 maturityDate,
        address redeemer,
        uint256 amount,
        uint256 minAmountRequired,
        uint256 maxSPDebt
    )
        external
        override
        onlyFixedLender
        returns (
            uint256 redeemAmountDiscounted,
            uint256 earningsSP,
            uint256 earningsTreasury
        )
    {
        PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

        earningsSP = pool.accrueEarnings(maturityDate, currentTimestamp());

        PoolLib.Position memory position = mpUserSuppliedAmount[maturityDate][
            redeemer
        ];

        // We verify if there are any penalties/fee for him because of
        // early withdrawal - if so: discount
        if (currentTimestamp() < maturityDate) {
            uint256 feeRate = interestRateModel.getRateToBorrow(
                maturityDate,
                block.timestamp,
                pool.borrowed + amount, // like asking for a loan full amount
                pool.supplied,
                maxSPDebt
            );
            redeemAmountDiscounted = amount.div_(1e18 + feeRate);
        } else {
            redeemAmountDiscounted = amount;
        }

        if (redeemAmountDiscounted < minAmountRequired) {
            revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
        }

        // We remove the supply from the offer
        smartPoolBorrowed += pool.withdrawMoney(
            position.copy().scaleProportionally(amount).principal,
            maxSPDebt
        );

        // All the fees go to unassigned or to the treasury
        uint256 unassignedEarnings;
        (unassignedEarnings, earningsTreasury) = PoolLib.distributeAccordingly(
            amount - redeemAmountDiscounted,
            pool.suppliedSP,
            redeemAmountDiscounted
        );
        maturityPools[maturityDate].addFee(unassignedEarnings);

        // the user gets discounted the full amount
        mpUserSuppliedAmount[maturityDate][redeemer] = position
            .reduceProportionally(amount);
    }

    /**
     * @dev Function to account for a repayment to a maturity pool (MP).
     * @param maturityDate maturity date / pool id where the asset should be accounted for
     * @param borrower address where the debt will be reduced
     * @param repayAmount amount that it will be repaid in the MP
     */
    function repayMP(
        uint256 maturityDate,
        address borrower,
        uint256 repayAmount,
        uint256 maxAmountAllowed
    )
        external
        override
        onlyFixedLender
        returns (
            uint256 spareRepayAmount,
            uint256 debtCovered,
            uint256 earningsSP,
            uint256 earningsTreasury
        )
    {
        RepayVars memory repayVars;

        PoolLib.MaturityPool storage pool = maturityPools[maturityDate];

        // SP supply needs to accrue its interests
        earningsSP = pool.accrueEarnings(maturityDate, currentTimestamp());

        // Amount Owed is (principal+fees)*penalties
        repayVars.amountOwed = getAccountBorrows(borrower, maturityDate);
        repayVars.position = mpUserBorrowedAmount[maturityDate][borrower];

        // We calculate the amount of the debt this covers, paying proportionally
        // the amount of interests on the overdue debt. If repay amount = amount owed,
        // then amountBorrowed is what should be discounted to the users account
        // Math.min to not go over repayAmount since we return exceeding money, but
        // hasn't been calculated yet
        debtCovered =
            (repayVars.position.fullAmount() *
                Math.min(repayAmount, repayVars.amountOwed)) /
            repayVars.amountOwed;
        repayVars.scaleDebtCovered = repayVars
            .position
            .copy()
            .scaleProportionally(debtCovered);

        // Early repayment allows you to get a discount from the unassigned earnings
        if (currentTimestamp() < maturityDate) {
            // We calculate the deposit fee considering the amount
            // of debt he'll pay
            (repayVars.discountFee, repayVars.feeSP) = interestRateModel
                .getYieldForDeposit(
                    pool.suppliedSP,
                    pool.earningsUnassigned,
                    repayVars.scaleDebtCovered.principal
                    // ^ this case shouldn't contain penalties since is before maturity date
                );

            earningsSP += repayVars.feeSP;

            // We verify that the user agrees to this discount
            if (debtCovered - repayVars.discountFee > maxAmountAllowed) {
                revert GenericError(ErrorCode.TOO_MUCH_SLIPPAGE);
            }

            // We remove the fee from unassigned earnings
            pool.removeFee(repayVars.discountFee);
        }

        // user paid more than it should. The fee gets kicked back to the user
        // through _spareRepayAmount_ and on the pool side it was removed by
        // calling _removeFee_ a few lines before ^
        spareRepayAmount = repayVars.discountFee;

        if (repayAmount > repayVars.amountOwed) {
            spareRepayAmount += repayAmount - repayVars.amountOwed;
            repayAmount = repayVars.amountOwed;
        }

        // We distribute penalties to those that supported (pre-repayment)
        uint256 newEarningsSP;
        (newEarningsSP, earningsTreasury) = PoolLib.distributeAccordingly(
            repayAmount - repayVars.scaleDebtCovered.fullAmount(),
            pool.suppliedSP,
            repayVars.scaleDebtCovered.principal
        );
        earningsSP += newEarningsSP;

        // We reduce the borrowed and we might decrease the SP debt
        repayVars.smartPoolDebtReduction = pool.repayMoney(
            repayVars.scaleDebtCovered.principal
        );
        smartPoolBorrowed -= repayVars.smartPoolDebtReduction;

        //
        // From now on: We update the user position
        //
        repayVars.position.reduceProportionally(debtCovered);
        if (repayVars.position.fullAmount() == 0) {
            cleanPosition(borrower, maturityDate);
        } else {
            // we proportionally reduce the values
            mpUserBorrowedAmount[maturityDate][borrower] = repayVars.position;
        }
    }

    /**
     * @dev Gets all borrows for a wallet in certain maturity (or ALL_MATURITIES)
     * @param who wallet to return status snapshot in the specified maturity date
     * @param maturityDate maturityDate where the borrow is taking place.
     * - Send the value 0 in order to get the snapshot for all maturities where the user borrowed
     * @return debt the amount the user deposited to the smart pool and the total money he owes from maturities
     */
    function getAccountBorrows(address who, uint256 maturityDate)
        public
        view
        override
        returns (uint256 debt)
    {
        if (maturityDate == 0) {
            uint256 borrowsLength = userMpBorrowed[who].length;
            for (uint256 i = 0; i < borrowsLength; i++) {
                debt += getAccountDebt(who, userMpBorrowed[who][i]);
            }
        } else {
            if (!TSUtils.isPoolID(maturityDate)) {
                revert GenericError(ErrorCode.INVALID_POOL_ID);
            }
            debt = getAccountDebt(who, maturityDate);
        }
    }

    /**
     * @dev Gets the total amount of borrowed money for a maturityDate
     * @param maturityDate maturity date
     */
    function getTotalMpBorrows(uint256 maturityDate)
        public
        view
        override
        returns (uint256)
    {
        if (!TSUtils.isPoolID(maturityDate)) {
            revert GenericError(ErrorCode.INVALID_POOL_ID);
        }
        return maturityPools[maturityDate].borrowed;
    }

    /**
     * @dev Cleans user's position from the blockchain making sure space is freed
     * @param borrower user's wallet
     * @param maturityDate maturity date
     */
    function cleanPosition(address borrower, uint256 maturityDate) internal {
        uint256[] memory userMaturitiesBorrowedList = userMpBorrowed[borrower];
        uint256 len = userMaturitiesBorrowedList.length;
        uint256 maturityIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userMaturitiesBorrowedList[i] == maturityDate) {
                maturityIndex = i;
                break;
            }
        }

        // We *must* have found the maturity in the list or our redundant data structure is broken
        assert(maturityIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        uint256[] storage storedList = userMpBorrowed[borrower];
        storedList[maturityIndex] = storedList[storedList.length - 1];
        storedList.pop();

        delete mpUserBorrowedAmount[maturityDate][borrower];
    }

    /**
     * @notice Internal function to get the debt + penalties of an account for a certain maturityDate
     * @param who wallet to return debt status for the specified maturityDate
     * @param maturityDate amount to be transfered
     * @return totalDebt : the total debt denominated in number of tokens
     */
    function getAccountDebt(address who, uint256 maturityDate)
        internal
        view
        returns (uint256 totalDebt)
    {
        PoolLib.Position memory position = mpUserBorrowedAmount[maturityDate][
            who
        ];
        totalDebt = position.principal + position.fee;
        uint256 secondsDelayed = TSUtils.secondsPre(
            maturityDate,
            currentTimestamp()
        );
        if (secondsDelayed > 0) {
            totalDebt += totalDebt.mul_(
                secondsDelayed * interestRateModel.penaltyRate()
            );
        }
    }

    /**
     * @notice Internal/virtual function to get the current timestamp (it gets overriden
     *         when writing tests)
     * @return current timestamp
     */
    function currentTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
