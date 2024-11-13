// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../interfaces/ISignatureTransfer.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAcrossBridge {
    function send(
        address token,
        uint256 amount,
        address receiver,
        uint256 destinationChainId,
        uint256 relayerFeePct
    ) external;
}

contract Goemon {
    struct Action {
        address token;
        address recipient;
        uint256 amount;
        uint256 frequency; // E.g., 1 month (in seconds)
        uint256 nextExecution;
    }

    ISignatureTransfer public immutable permit2;
    uint256 private s_countActions = 0;
    address public usdcToken; // USDC token address on Ethereum
    IAcrossBridge public acrossBridge; // Across Bridge contract address
    mapping(address => mapping(uint256 => Action)) public userActions;

    constructor(
        address permit2Address,
        address _usdcToken,
        address _acrossBridge
    ) {
        // Initialize Permit2 contract instance
        permit2 = ISignatureTransfer(permit2Address);
        usdcToken = _usdcToken;
        acrossBridge = IAcrossBridge(_acrossBridge);
    }

    event TransferInitiated(
        address indexed sender,
        address indexed receiver,
        uint256 amount,
        uint256 chainId
    );

    event PermitTransfer(
        address indexed token,
        address indexed owner,
        address indexed receiver,
        uint256 amount
    );
    event ActionCreated(
        address indexed user,
        uint256 indexed actionIndex,
        address indexed recipient,
        uint256 amount,
        uint256 frequency
    );
    event ActionExecuted(address indexed user, uint256 actionIndex);
    event ActionCanceled(address indexed user, uint256 actionIndex);

    ////////////////////  action  ////////////////////////
    // create new action
    function createAction(
        address _token,
        address _recipient,
        uint256 _amount,
        uint256 _frequency
    ) external {
        require(_token != address(0), "Invalid token address");
        require(_recipient != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be greater than 0");
        require(_frequency > 0, "Frequency must be greater than 0");

        Action memory newAction = Action({
            token: _token,
            recipient: _recipient,
            amount: _amount,
            frequency: _frequency,
            nextExecution: block.timestamp + _frequency
        });
        s_countActions += 1;
        userActions[msg.sender][s_countActions] = newAction;

        emit ActionCreated(
            msg.sender,
            s_countActions,
            _recipient,
            _amount,
            _frequency
        );
    }

    function executeAction(
        address _user,
        uint256 _actionIndex
    ) external payable {
        require(_actionIndex <= s_countActions, "Invalid action index");
        Action storage action = userActions[_user][_actionIndex];
        require(block.timestamp >= action.nextExecution, "Execution too early");
        require(msg.value == action.amount, "Send wrong amount");

        (bool success, ) = action.recipient.call{value: msg.value}("");
        require(success, "Transaction failed");

        emit ActionExecuted(_user, _actionIndex);
    }

    // execute action with permit
    function executeActionWithPermit(
        address _user,
        uint256 _actionIndex,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) public {
        require(_actionIndex <= s_countActions, "Invalid action index");

        Action storage action = userActions[_user][_actionIndex];
        require(block.timestamp >= action.nextExecution, "Execution too early");

        transferWithPermit(
            action.token,
            action.recipient,
            action.amount,
            _nonce,
            _deadline,
            _signature
        );

        action.nextExecution += action.frequency;
        emit ActionExecuted(_user, _actionIndex);
    }

    // check for condition and execute action
    function checkAndExecute(
        address _user,
        uint256 _actionIndex,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external {
        if (block.timestamp >= userActions[_user][_actionIndex].nextExecution) {
            executeActionWithPermit(
                _user,
                _actionIndex,
                _nonce,
                _deadline,
                _signature
            );
        }
    }

    // delete action
    function cancelAction(uint256 _actionIndex) external {
        require(_actionIndex <= s_countActions, "Invalid action index");

        delete (userActions[msg.sender][_actionIndex]);
        emit ActionCanceled(msg.sender, _actionIndex);
    }

    // permit2 transfer
    function transferWithPermit(
        address token,
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) public {
        require(amount > 0, "Amount must be greater than zero");
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        require(balance >= amount, "Insufficient token balance");

        // Define the permit data structure
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer
            .PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: token,
                    amount: amount
                }),
                nonce: nonce,
                deadline: deadline
            });

        // Define the transfer request
        ISignatureTransfer.SignatureTransferDetails
            memory transferDetails = ISignatureTransfer
                .SignatureTransferDetails({
                    to: receiver,
                    requestedAmount: amount
                });

        // Execute the permit transfer
        permit2.permitTransferFrom(permit, transferDetails, msg.sender, sig);
        emit PermitTransfer(token, msg.sender, receiver, amount);
    }

    function transferUSDCToOptimism(
        address receiver,
        uint256 amount,
        uint256 relayerFeePct
    ) external {
        require(amount > 0, "Amount must be greater than zero");

        // Transfer USDC using the Across Bridge
        acrossBridge.send(usdcToken, amount, receiver, 10, relayerFeePct); // Chain ID 10 for Optimism
    }
}
