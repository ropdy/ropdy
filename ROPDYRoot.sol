// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./library/AddressQueue.sol";

interface IPriceConversion {
    function usdToRama(uint256 microUSD) external view returns (uint256);

    function ramaToUSD(uint256 ramaAmount) external view returns (uint256);
}

contract ROPDYRoot is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using AddressQueue for AddressQueue.Queue;

    enum Package {
        Starter,
        Silver,
        Gold,
        Platinum,
        Diamond
    }

    enum PaymentType {
        CP1,
        CP2,
        MOD1,
        MOD2,
        MOD3,
        MOD4
    }

    struct DownlineMember {
        address member;
        uint256 level;
    }

    struct Payment {
        address from;
        address to;
        uint256 ramaAmount;
        uint256 usdAmount;
        uint256 feeRama;
        uint256 feeUSD;
        uint256 netRama;
        uint256 netUSD;
        PaymentType paymentType;
        uint256 timestamp;
        uint256 circleIndex;
    }

    struct Circle {
        Package packageType;
        uint256 index;
        uint8 paymentCount;
        bool isCompleted;
        uint256 createdAt;
        uint256 completedAt;
        address[6] paymentsIn;
        Payment[2] paymentsOut;
        uint256[6] paymentSources; //0-CP1 ,1-CP2
    }

    // Define a struct to hold all circle details
    struct CircleDetails {
        bool isCompleted;
        uint8 paymentCount;
        uint256 createdAt;
        uint256 completedAt;
        address[6] froms;
        uint256[6] sources;
        Payment cp1;
        Payment cp2;
        Payment[] cp1Received;
        Payment[] cp2Received;
    }

    struct MOD4Tracker {
        uint8 hitCount;
        uint256 lastHitTimestamp;
        bool isInPool;
    }

    struct MissedPayment {
        uint256 timestamp;
        address from;
        uint256 amount;
        uint256 amountInUSD;
        Package pkg;
        uint256 isCP1;
        uint256 reason;
    }

    struct User {
        uint256 id;
        address wallet;
        address sponsor;
        uint256 registrationTime;
        address[] invitedUsers;
        mapping(Package => Circle[]) circles;
    }

    struct HeldFundsUser {
        uint256 amountHeldInRAMA;
        uint256 amountHeldInUSD;
    }

    IPriceConversion public priceFeed;
    address public platformFeeReceiver;
    address public rootUser;
    address public mod3Address;

    uint256 public platformFeePercent;
    uint256 public totalUserCount;
    uint256 public totalEarnedUSD;
    uint256 public totalEarnedRAMA;

    uint256 public totalGlobalPurchasedCircles;
    uint256 public totalGlobalRePurchasedCircles;

    uint256 public getTotalOfGlobalHeldFundsInRAMA;
    uint256 public getTotalOfGlobalHeldFundsInUSD;

    mapping(address => User) public users;
    mapping(address => uint256) public addressToUserId;
    mapping(uint256 => address) public userIdToAddress;

    mapping(address => mapping(Package => mapping(uint256 => Payment[])))
        public cp1SentPayments;
    mapping(address => mapping(Package => mapping(uint256 => Payment[])))
        public cp1ReceivedPayments;
    mapping(address => mapping(Package => mapping(uint256 => Payment[])))
        public cp2SentPayments;
    mapping(address => mapping(Package => mapping(uint256 => Payment[])))
        public cp2ReceivedPayments;

    event UserRegistered(
        address indexed user,
        uint256 indexed userId,
        address indexed sponsor
    );
    event PurchaseStarted(address indexed user, Package pkg, uint256 index);
    event PurchaseCompleted(address indexed user, Package pkg, uint256 index);
    event CP1Sent(
        address indexed from,
        address indexed to,
        Package pkg,
        uint256 amount
    );
    event CP1Received(
        address indexed from,
        address indexed to,
        Package pkg,
        uint256 amount
    );
    event CP2Sent(
        address indexed from,
        address indexed to,
        Package pkg,
        uint256 amount
    );
    event CP2Received(
        address indexed from,
        address indexed to,
        Package pkg,
        uint256 amount
    );

    event HeldFund(
        address indexed heldfor,
        Package pkg,
        uint256 amount,
        uint256 circle,
        uint256 paymentCounts,
        uint256 mod
    );

    event MOD1(address indexed from, address indexed to);
    event MOD2(address indexed from, address indexed to);
    event MOD3(address indexed to, uint256 amount);
    event MOD4(address indexed to, uint256 amount, uint8 hitType);
    event Received(address indexed from, uint256 amount);

    mapping(Package => uint256) public packagePrices;
    mapping(Package => uint256) public packageGlobalPaymentCount;

    mapping(Package => uint256) public mod4GlobalHits;

    mapping(address => mapping(Package => MOD4Tracker)) public mod4Tracker;
    mapping(address => MissedPayment[]) public missedPaymentsByUser;

    mapping(address => mapping(Package => uint256)) public totalEarnings;
    mapping(address => mapping(Package => uint256)) public cp1Earnings;
    mapping(address => mapping(Package => uint256)) public cp2Earnings;
    mapping(address => mapping(Package => uint256)) public mod1Earnings;
    mapping(address => mapping(Package => uint256)) public mod2Earnings;
    mapping(address => mapping(Package => uint256)) public mod3Earnings;
    mapping(address => mapping(Package => uint256)) public mod4Earnings;
    mapping(address => mapping(Package => HeldFundsUser)) public heldFunds;
    mapping(Package => AddressQueue.Queue) public mod4Pool;
    mapping(Package => mapping(uint256 => address)) public Mod4PoolHitMember;

    mapping(Package => mapping(uint256 => mapping(uint256 => address)))
        public Mod4PoolHitMemberV2;
    mapping(address => mapping(Package => uint256)) public totalEarningsInUSD;

    function initialize(address _priceFeed) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        platformFeeReceiver = msg.sender;
        mod3Address = msg.sender;
        priceFeed = IPriceConversion(_priceFeed);

        platformFeePercent = 5;
        totalUserCount = 1;

        User storage root = users[msg.sender];
        root.id = totalUserCount;
        root.wallet = msg.sender;
        root.registrationTime = block.timestamp;
        root.sponsor = address(0);

        addressToUserId[msg.sender] = totalUserCount;
        userIdToAddress[totalUserCount] = msg.sender;
        rootUser = msg.sender;

        packagePrices[Package.Starter] = 20 * 1e6;
        packagePrices[Package.Silver] = 40 * 1e6;
        packagePrices[Package.Gold] = 80 * 1e6;
        packagePrices[Package.Platinum] = 160 * 1e6;
        packagePrices[Package.Diamond] = 320 * 1e6;

        emit UserRegistered(msg.sender, totalUserCount, address(0));
    }

    modifier onlyRegistered() {
        require(users[msg.sender].id != 0, "Not registered");
        _;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }

    function isUserRegistered(address user) public view returns (bool) {
        return users[user].id != 0;
    }

    function getSponsor(address user) external view returns (address) {
        return users[user].sponsor;
    }

    // function register(
    //     address sponsor
    // ) external payable whenNotPaused nonReentrant {
    //     require(!isUserRegistered(msg.sender), "Already registered");
    //     require(isUserRegistered(sponsor), "Invalid sponsor");
    //     require(msg.sender != sponsor, "Self-sponsoring not allowed");

    //     uint256 price = getPackagePriceInRAMA(Package.Starter);
    //     _validateAmount(price);

    //     totalUserCount++;
    //     uint256 newUserId = totalUserCount;

    //     User storage user = users[msg.sender];
    //     user.id = newUserId;
    //     user.wallet = msg.sender;
    //     user.sponsor = sponsor;
    //     user.registrationTime = block.timestamp;

    //     addressToUserId[msg.sender] = newUserId;
    //     userIdToAddress[newUserId] = msg.sender;
    //     users[sponsor].invitedUsers.push(msg.sender);

    //     emit UserRegistered(msg.sender, newUserId, sponsor);
    //     _startNewPurchase(msg.sender, Package.Starter, msg.value, false);
    // }

    // function buyPackage(Package pkg) external payable nonReentrant {
    //     require(isUserRegistered(msg.sender), "User not registered");

    //     uint256 price = getPackagePriceInRAMA(pkg);
    //     _validateAmount(price);

    //     _startNewPurchase(msg.sender, pkg, msg.value, false);
    // }

    function triggerNextCircleFromHeld(address receiver, Package pkg) internal {
        // require(isUserRegistered(receiver), "User not registered");

        HeldFundsUser memory held = heldFunds[receiver][pkg];
        require(held.amountHeldInRAMA > 0, "No held funds");

        getTotalOfGlobalHeldFundsInRAMA -= held.amountHeldInRAMA;
        getTotalOfGlobalHeldFundsInUSD -= held.amountHeldInUSD;
        heldFunds[receiver][pkg].amountHeldInRAMA = 0;
        heldFunds[receiver][pkg].amountHeldInUSD = 0;

        _startNewPurchase(receiver, pkg, held.amountHeldInRAMA, true);
        _tryPushNextActiveCircleToPool(receiver, pkg); // pushes next circle to MOD4 pool
    }

    function _startNewPurchase(
        address user,
        Package pkg,
        uint256 amount,
        bool isRePurchase
    ) internal {
        Circle[] storage circles = users[user].circles[pkg];
        uint256 index = circles.length;

        circles.push();
        Circle storage c = circles[index];
        c.packageType = pkg;
        c.index = index;
        c.createdAt = block.timestamp;
        c.paymentCount = 0;
        c.isCompleted = false;

        totalEarnedUSD += getPackagePriceInUSD(pkg);
        totalEarnedRAMA += amount;

        if (isRePurchase || index > 0) {
            totalGlobalRePurchasedCircles += 1;
        } else {
            totalGlobalPurchasedCircles += 1;
        }

        emit PurchaseStarted(user, pkg, index);

        if (!mod4Pool[pkg].contains(user)) {
            _addToMod4Pool(user, pkg, index);
        }

        _processInitialPayments(user, pkg, amount);
    }

    function _validateAmount(uint256 expectedAmount) internal view {
        uint256 upperLimit = (expectedAmount * 101) / 100;
        require(msg.value >= expectedAmount, "Insufficient RAMA");
        require(msg.value <= upperLimit, "RAMA exceeds allowed limit");
    }

    function _processInitialPayments(
        address user,
        Package pkg,
        uint256 amount
    ) internal {
        packageGlobalPaymentCount[pkg] = packageGlobalPaymentCount[pkg] + 1;
        uint256 half = amount / 2;

        _handleCP1(user, pkg, half);
        _handleCP2(user, pkg, amount - half);
    }

    function fillCircle(
        address sender,
        address receiver,
        Package pkg,
        uint256 amount,
        uint256 paymentType,
        uint256 modnum,
        uint256 hit
    ) internal {
        if (_canReceive(receiver, pkg) && (modnum != 3)) {
            uint256 index = _getActiveCircleIndex(receiver, pkg);
            Circle storage c = users[receiver].circles[pkg][index];
            uint8 count = c.paymentCount; //0 //1  //2  //3  //4  //5

            c.paymentsIn[count] = sender;
            c.paymentSources[count] = paymentType;
            c.paymentCount += 1; //1   //2  //3  //4  //5  //6

            PaymentType pt = modnum == 1
                ? PaymentType.MOD1
                : modnum == 2
                    ? PaymentType.MOD2
                    : modnum == 3
                        ? PaymentType.MOD3
                        : modnum == 4
                            ? PaymentType.MOD4
                            : PaymentType.CP1;

            Payment memory p = _buildPayment(
                sender,
                receiver,
                amount,
                pt,
                index,
                pkg
            );

            //get senders settlement

            if (paymentType == 1) {
                users[sender]
                .circles[pkg][_getActiveCircleIndex(sender, pkg)].paymentsOut[
                        0
                    ] = p;
                cp1SentPayments[sender][pkg][_getActiveCircleIndex(sender, pkg)]
                    .push(p);
                cp1ReceivedPayments[receiver][pkg][index].push(p);
                emit CP1Sent(sender, receiver, pkg, amount);
                emit CP1Received(sender, receiver, pkg, amount);
            } else {
                users[sender]
                .circles[pkg][_getActiveCircleIndex(sender, pkg)].paymentsOut[
                        1
                    ] = p;
                cp2SentPayments[sender][pkg][_getActiveCircleIndex(sender, pkg)]
                    .push(p);
                cp2ReceivedPayments[receiver][pkg][index].push(p);

                emit CP2Sent(sender, receiver, pkg, amount);
                emit CP2Received(sender, receiver, pkg, amount);
            }

            if (modnum == 4) {
                mod4Earnings[receiver][pkg] += amount;
            } else if (modnum == 2) {
                mod2Earnings[receiver][pkg] += amount;
                emit MOD2(sender, receiver);
            } else if (modnum == 1) {
                mod1Earnings[receiver][pkg] += amount;
                emit MOD1(sender, receiver);
            }

            totalEarnings[receiver][pkg] += amount;
            totalEarningsInUSD[receiver][pkg] += (
                pkg == Package.Starter
                    ? 10
                    : pkg == Package.Silver
                        ? 20
                        : pkg == Package.Gold
                            ? 40
                            : pkg == Package.Platinum
                                ? 80
                                : 160
            );
            if (paymentType == 1) cp1Earnings[receiver][pkg] += p.netRama;
            else cp2Earnings[receiver][pkg] += p.netRama;

            if (c.paymentCount < 4) {
                (bool success, ) = payable(receiver).call{value: p.netRama}("");

                require(success, "RAMA transfer to receiver failed ");
            } else if (c.paymentCount == 5) {
                heldFunds[receiver][pkg].amountHeldInRAMA += p.netRama;
                heldFunds[receiver][pkg].amountHeldInUSD += p.netUSD;
                getTotalOfGlobalHeldFundsInRAMA += p.netRama;
                getTotalOfGlobalHeldFundsInUSD += p.netUSD;
                emit HeldFund(
                    receiver,
                    pkg,
                    p.netRama,
                    index,
                    c.paymentCount,
                    modnum
                );
            } else if (c.paymentCount == 6) {
                heldFunds[receiver][pkg].amountHeldInRAMA += p.netRama;
                heldFunds[receiver][pkg].amountHeldInUSD += p.netUSD;
                getTotalOfGlobalHeldFundsInRAMA += p.netRama;
                getTotalOfGlobalHeldFundsInUSD += p.netUSD;
                emit HeldFund(
                    receiver,
                    pkg,
                    p.netRama,
                    index,
                    c.paymentCount,
                    modnum
                );

                c.isCompleted = true;
                c.completedAt = block.timestamp;
                emit PurchaseCompleted(receiver, pkg, c.index);
                _removeFromMod4Pool(receiver, pkg);

                triggerNextCircleFromHeld(receiver, pkg);
            }

            if (modnum == 4) {
                emit MOD4(receiver, amount, uint8(hit));
            }
        } else {
            if (receiver == platformFeeReceiver && modnum == 3) {
                Payment memory p = _buildPayment(
                    sender,
                    receiver,
                    amount,
                    PaymentType.MOD3,
                    1,
                    pkg
                );

                users[sender]
                .circles[pkg][_getActiveCircleIndex(sender, pkg)].paymentsOut[
                        1
                    ] = p;
                cp2SentPayments[sender][pkg][_getActiveCircleIndex(sender, pkg)]
                    .push(p);

                emit CP2Sent(sender, receiver, pkg, amount);
                emit CP2Received(sender, receiver, pkg, amount);
            } else {
                _recordMissed(
                    sender,
                    receiver,
                    amount,
                    pkg,
                    paymentType,
                    10 //"Missed CP2 - MOD4 ineligible"
                );
            }
            (bool success, ) = payable(receiver).call{value: amount}("");

            require(success, "RAMA transfered to admin failed");
        }
    }

    function _handleCP1(address from, Package pkg, uint256 amount) internal {
        address sponsor = users[from].sponsor;

        fillCircle(from, sponsor, pkg, amount, 1, 0, 0);
    }

    function _handleCP2(address from, Package pkg, uint256 amount) internal {
        uint256 globalCount = packageGlobalPaymentCount[pkg];
        bool paid = false;

        if (globalCount % 8 == 0 && mod3Address != address(0)) {
            fillCircle(from, mod3Address, pkg, amount, 2, 3, 0);

            paid = true;
        }

        if (!paid && globalCount % 5 == 0) {
            address upline = _getNthUpline(from, 3);
            if (_canReceive(upline, pkg)) {
                fillCircle(from, upline, pkg, amount, 2, 2, 0);

                paid = true;
            } else {
                missedPaymentsByUser[upline].push(
                    MissedPayment({
                        timestamp: block.timestamp,
                        from: from,
                        amount: amount,
                        amountInUSD: packagePrices[pkg] / 2,
                        pkg: pkg,
                        isCP1: 0,
                        reason: 22 //"Missed CP1 - no eligible active circle"
                    })
                );
            }
        }

        if (!paid && globalCount % 3 == 0) {
            address upline = _getNthUpline(from, 2);
            if (_canReceive(upline, pkg)) {
                fillCircle(from, upline, pkg, amount, 2, 1, 0);

                paid = true;
            } else {
                missedPaymentsByUser[upline].push(
                    MissedPayment({
                        timestamp: block.timestamp,
                        from: from,
                        amount: amount,
                        amountInUSD: packagePrices[pkg] / 2,
                        pkg: pkg,
                        isCP1: 0,
                        reason: 21
                    })
                );
            }
        }

        if (!paid) {
            _handleMOD4(from, pkg, amount);
        }
    }

    function _buildPayment(
        address from,
        address to,
        uint256 amount,
        PaymentType pType,
        uint256 circleIndex,
        Package pkg
    ) internal returns (Payment memory) {
        uint256 fee = (amount * platformFeePercent) / 100;
        uint256 net = amount - fee;
        uint256 usdAmount = packagePrices[pkg] / 2;
        uint256 feeUSD = (usdAmount * platformFeePercent) / 100;
        uint256 netUSD = usdAmount - feeUSD;

        if (fee > 0 && (to != platformFeeReceiver)) {
            (bool success, ) = payable(platformFeeReceiver).call{value: fee}(
                ""
            );
            require(success, "RAMA transfer for platform fee failed");
        }

        return
            Payment({
                from: from,
                to: to,
                ramaAmount: amount,
                usdAmount: usdAmount,
                feeRama: fee,
                feeUSD: feeUSD,
                netRama: net,
                netUSD: netUSD,
                paymentType: pType,
                timestamp: block.timestamp,
                circleIndex: circleIndex
            });
    }

    function _handleMOD4(address sender, Package pkg, uint256 amount) internal {
        uint256 oldMod4GlobalHits = mod4GlobalHits[pkg];
        uint256 hit = oldMod4GlobalHits % 3;
        mod4GlobalHits[pkg]++;

        address receiver;

        address[] memory pool = mod4Pool[pkg].getAll();
        uint256 len = pool.length;

        if (len == 0) {
            receiver = platformFeeReceiver;
        } else if (hit == 0) {
            // peekFront

            receiver = mod4Pool[pkg].peekFront();
        } else if (hit == 1) {
            receiver = pool[len / 2];
        } else {
            receiver = pool[len >= 2 ? len - 2 : 0];
        }

        Mod4PoolHitMemberV2[pkg][oldMod4GlobalHits][hit] = receiver;

        if (_canReceive(receiver, pkg)) {
            fillCircle(sender, receiver, pkg, amount, 2, 4, hit);
        } else {
            cp2Earnings[platformFeeReceiver][pkg] += amount;

            (bool success, ) = payable(platformFeeReceiver).call{value: amount}(
                ""
            );
            require(success, "RAMA transfer for payout failed");

            _recordMissed(
                sender,
                receiver,
                amount,
                pkg,
                2,
                24 //"Missed CP2 - MOD4 ineligible"
            );
        }
    }

    function _getNthUpline(
        address user,
        uint256 level
    ) internal view returns (address) {
        address current = user;
        for (uint256 i = 0; i < level; i++) {
            current = users[current].sponsor;
            if (current == address(0)) break;
        }
        return current;
    }

    function _getActiveCircleIndex(
        address user,
        Package pkg
    ) internal view returns (uint256) {
        Circle[] storage circles = users[user].circles[pkg];
        for (uint256 i = 0; i < circles.length; i++) {
            if ((!circles[i].isCompleted) && (circles[i].paymentCount < 6)) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _canReceive(address user, Package pkg) internal view returns (bool) {
        if (_getActiveCircleIndex(user, pkg) != type(uint256).max) {
            return true;
        }
        return false;
    }

    function _getLatestCircleIndex(
        address user,
        Package pkg
    ) internal view returns (uint256) {
        uint256 len = users[user].circles[pkg].length;
        return len > 0 ? len - 1 : 0;
    }

    function _recordMissed(
        address from,
        address to,
        uint256 amount,
        Package pkg,
        uint256 paymentType,
        uint256 reason
    ) internal {
        missedPaymentsByUser[to].push(
            MissedPayment({
                timestamp: block.timestamp,
                from: from,
                amount: amount,
                amountInUSD: packagePrices[pkg] / 2,
                pkg: pkg,
                isCP1: paymentType,
                reason: reason
            })
        );
    }

    function _addToMod4Pool(address user, Package pkg, uint256) internal {
        if (mod4Pool[pkg].contains(user)) return;
        mod4Pool[pkg].enqueue(user);
        mod4Tracker[user][pkg] = MOD4Tracker(0, block.timestamp, true);
    }

    function _removeFromMod4Pool(address user, Package pkg) internal {
        AddressQueue.Queue storage q = mod4Pool[pkg];
        if (!q.contains(user)) return;

        if (q.peekFront() == user) {
            // If user is at the front, dequeue properly
            q.dequeue();
        } else {
            // Else just remove from middle
            q.remove(user);
        }

        mod4Tracker[user][pkg].isInPool = false;
    }

    function _tryPushNextActiveCircleToPool(
        address user,
        Package pkg
    ) internal {
        if (mod4Pool[pkg].contains(user)) return;

        uint256 index = _getActiveCircleIndex(user, pkg);
        if (index != type(uint256).max) {
            _addToMod4Pool(user, pkg, index);
        }
    }

    // === Admin Functions ===
    function updateSettings(
        address corraddress,
        uint256 corrfee,
        uint8 option
    ) external onlyOwner {
        //1 - setplatformfee  //2- setPriceFeed  //3  -setMod3Address //4- setPlatformFeeReceiver

        require(option > 0 && option <= 4, "select a valid option");

        if (option == 1) {
            require(corrfee <= 10, "Max  10%");
            platformFeePercent = corrfee;
        } else if (option == 2) {
            require(corraddress != address(0), "Invalid ");
            priceFeed = IPriceConversion(corraddress);
        } else if (option == 3) {
            require(corraddress != address(0), "Invalid");
            mod3Address = corraddress;
        } else if (option == 4) {
            require(corraddress != address(0), "Invalid");
            platformFeeReceiver = corraddress;
        }
    }

    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid");
        require(amount <= address(this).balance, "Insufficient");
        payable(to).transfer(amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getUserId(address user) external view returns (uint256) {
        return addressToUserId[user];
    }

    function getUserById(uint256 id) external view returns (address) {
        return userIdToAddress[id];
    }

    function getDirectReferrals(
        address user
    ) external view returns (address[] memory) {
        return users[user].invitedUsers;
    }

    function getUserCircleCount(
        address user,
        Package pkg
    ) external view returns (uint256) {
        return users[user].circles[pkg].length;
    }

    function getMissedPayments(
        address user
    ) external view returns (MissedPayment[] memory) {
        return missedPaymentsByUser[user];
    }

    function getGlobalReportStats()
        external
        view
        returns (uint256, uint256, uint256)
    {
        return (totalUserCount, totalEarnedUSD, totalEarnedRAMA);
    }

    function getCircleDetails(
        address user,
        Package pkg,
        uint256 index
    ) external view returns (CircleDetails memory) {
        Circle storage c = users[user].circles[pkg][index];

        return
            CircleDetails({
                isCompleted: c.isCompleted,
                paymentCount: c.paymentCount,
                createdAt: c.createdAt,
                completedAt: c.completedAt,
                froms: c.paymentsIn,
                sources: c.paymentSources,
                cp1: c.paymentsOut[0],
                cp2: c.paymentsOut[1],
                cp1Received: cp1ReceivedPayments[user][pkg][index],
                cp2Received: cp2ReceivedPayments[user][pkg][index]
            });
    }

    function getCP1PaymentsByUserAndCircle(
        address user,
        Package pkg,
        uint256 circleIndex
    ) external view returns (Payment[] memory) {
        return cp1SentPayments[user][pkg][circleIndex];
    }

    function getCP2PaymentsByUserAndCircle(
        address user,
        Package pkg,
        uint256 circleIndex
    ) external view returns (Payment[] memory) {
        return cp2SentPayments[user][pkg][circleIndex];
    }

    // === Price Helper ===
    function getPackagePriceInUSD(Package pkg) public view returns (uint256) {
        return packagePrices[pkg];
    }

    function getPackagePriceInRAMA(Package pkg) public view returns (uint256) {
        return priceFeed.usdToRama(packagePrices[pkg]);
    }

    function getUserRegistrationTime(
        address user
    ) external view returns (uint256) {
        return users[user].registrationTime;
    }

    function getHeldFunds(
        address user,
        Package pkg
    ) public view returns (HeldFundsUser memory hf) {
        return heldFunds[user][pkg];
    }

    function getCircle(
        address user,
        Package pkg,
        uint256 index
    ) external view returns (Circle memory) {
        return users[user].circles[pkg][index];
    }

    function registerMigratedUser(
        address userToBeMigrated,
        address sponsor,
        uint256 amountInRAMA,
        uint8 count
    ) external onlyOwner {
        require(!isUserRegistered(userToBeMigrated), "Already registered");
        // require(isUserRegistered(sponsor), "Invalid sponsor");
        require(userToBeMigrated != sponsor, "Self-sponsoring not allowed");

        // uint256 price = getPackagePriceInRAMA(Package.Starter);
        // _validateAmount(price);

        totalUserCount++;
        uint256 newUserId = totalUserCount;

        User storage user = users[userToBeMigrated];
        user.id = newUserId;
        user.wallet = userToBeMigrated;
        user.sponsor = sponsor;
        user.registrationTime = block.timestamp;

        addressToUserId[userToBeMigrated] = newUserId;
        userIdToAddress[newUserId] = userToBeMigrated;
        users[sponsor].invitedUsers.push(userToBeMigrated);

        emit UserRegistered(userToBeMigrated, newUserId, sponsor);

        if (count != 0) {
            for (uint8 i = 0; i < count; i++) {
                _startNewPurchaseMigratedUser(
                    userToBeMigrated,
                    Package.Starter,
                    amountInRAMA,
                    false
                );
            }
        }
    }

    function buyPackageMigratedUser(
        address userToBeMigrated,
        Package pkg,
        uint256 amountInRAMA,
        uint8 count
    ) external onlyOwner {
        require(isUserRegistered(userToBeMigrated), "User not registered");

        for (uint8 i = 0; i < count; i++) {
            _startNewPurchaseMigratedUser(
                userToBeMigrated,
                pkg,
                amountInRAMA,
                false
            );
        }
    }

    function userIsInMod4Pool(
        address user,
        Package pkg
    ) public view returns (bool) {
        return mod4Pool[pkg].contains(user);
    }

    function _startNewPurchaseMigratedUser(
        address user,
        Package pkg,
        uint256 amount,
        bool isRePurchase
    ) internal {
        Circle[] storage circles = users[user].circles[pkg];
        uint256 index = circles.length;

        circles.push();
        Circle storage c = circles[index];
        c.packageType = pkg;
        c.index = index;
        c.createdAt = block.timestamp;
        c.paymentCount = 0;
        c.isCompleted = false;

        totalEarnedUSD += getPackagePriceInUSD(pkg);
        totalEarnedRAMA += amount;

        if (isRePurchase || index > 0) {
            totalGlobalRePurchasedCircles += 1;
        } else {
            totalGlobalPurchasedCircles += 1;
        }

        emit PurchaseStarted(user, pkg, index);

        if (!userIsInMod4Pool(user, pkg)) {
            _addToMod4Pool(user, pkg, index);
        }
    }

    function getMod4QueueDetailsForUser(
        address user,
        Package pkg
    ) external view returns (bool isInQueue, uint256 queueIndex) {
        AddressQueue.Queue storage q = mod4Pool[pkg];

        isInQueue = q.contains(user);
        queueIndex = isInQueue ? q.indexInQueue[user] : type(uint256).max;
    }

    function getMod4PoolHoles(
        Package pkg
    ) external view returns (uint256[] memory holes, uint256 totalSlots) {
        AddressQueue.Queue storage q = mod4Pool[pkg];
        holes = q.getAllHoles();
        totalSlots = q.tail; // Total slots allocated (including holes)
        return (holes, totalSlots);
    }

    function getMod4PoolStructure(
        Package pkg
    )
        external
        view
        returns (address[] memory queueArray, bool[] memory indexMapping)
    {
        AddressQueue.Queue storage q = mod4Pool[pkg];
        queueArray = q.getAll();
        indexMapping = new bool[](queueArray.length);

        for (uint256 i = 0; i < queueArray.length; i++) {
            indexMapping[i] = (queueArray[i] != address(0));
        }

        return (queueArray, indexMapping);
    }

    function getMod4PoolStructureAll(
        Package pkg
    )
        external
        view
        returns (address[] memory queueArray, bool[] memory indexMapping)
    {
        AddressQueue.Queue storage q = mod4Pool[pkg];

        // Initialize arrays with size = q.tail (total slots)
        queueArray = new address[](q.tail);
        indexMapping = new bool[](q.tail);

        // Fill both arrays
        for (uint256 i = 0; i < q.tail; i++) {
            queueArray[i] = q.items[i];
            indexMapping[i] = (q.items[i] != address(0));
        }

        return (queueArray, indexMapping);
    }

    function getDirectDownlines(
        address user
    ) external view returns (address[] memory) {
        return users[user].invitedUsers;
    }

    function getDownlinesAtLevel(
        address user,
        uint256 level
    ) external view returns (address[] memory) {
        require(level > 0, "Level must be at least 1");

        // First, count how many addresses are at the target level
        uint256 count = _countDownlinesAtLevel(user, 0, level);

        // Prepare the result array
        address[] memory result = new address[](count);

        // Fill the result array
        _collectDownlinesAtLevel(user, 0, level, result, 0);

        return result;
    }

    // Helper to count addresses at a specific level
    function _countDownlinesAtLevel(
        address user,
        uint256 currentLevel,
        uint256 targetLevel
    ) internal view returns (uint256) {
        if (currentLevel == targetLevel) {
            return 1;
        }
        uint256 count = 0;
        for (uint256 i = 0; i < users[user].invitedUsers.length; i++) {
            count += _countDownlinesAtLevel(
                users[user].invitedUsers[i],
                currentLevel + 1,
                targetLevel
            );
        }
        return count;
    }

    // Helper to collect addresses at a specific level
    function _collectDownlinesAtLevel(
        address user,
        uint256 currentLevel,
        uint256 targetLevel,
        address[] memory result,
        uint256 index
    ) internal view returns (uint256) {
        if (currentLevel == targetLevel) {
            result[index] = user;
            return index + 1;
        }
        for (uint256 i = 0; i < users[user].invitedUsers.length; i++) {
            index = _collectDownlinesAtLevel(
                users[user].invitedUsers[i],
                currentLevel + 1,
                targetLevel,
                result,
                index
            );
        }
        return index;
    }

    // Helper function to count all downlines
    function _countAllDownlines(address user) public view returns (uint256) {
        uint256 count = users[user].invitedUsers.length;
        for (uint256 i = 0; i < users[user].invitedUsers.length; i++) {
            count += _countAllDownlines(users[user].invitedUsers[i]);
        }
        return count;
    }

    // Modified recursive function (now returns void)
    function _getAllDownlinesRecursive(
        address user,
        DownlineMember[] memory downlines,
        uint256 currentIndex
    ) public view returns (uint256) {
        for (uint256 i = 0; i < users[user].invitedUsers.length; i++) {
            downlines[currentIndex] = DownlineMember({
                member: users[user].invitedUsers[i],
                level: i
            });
            currentIndex++;
            currentIndex = _getAllDownlinesRecursive(
                users[user].invitedUsers[i],
                downlines,
                currentIndex
            );
        }
        return currentIndex;
    }

    function getFullUpline(
        address user
    ) external view returns (address[] memory, uint256[] memory) {
        // First count the upline levels
        uint256 levels = 0;
        address current = user;

        while (users[current].sponsor != address(0)) {
            levels++;
            current = users[current].sponsor;
        }

        // Create array and populate
        address[] memory upline = new address[](levels);
        uint256[] memory level = new uint256[](levels);
        current = user;

        for (uint256 i = 0; i < levels; i++) {
            upline[i] = users[current].sponsor;
            level[i] = i;
            current = upline[i];
        }

        return (upline, level);
    }

    function getUplineAtLevel(
        address user,
        uint256 level
    ) external view returns (address) {
        require(level > 0, "Level must be at least 1");

        address current = user;
        for (uint256 i = 0; i < level; i++) {
            current = users[current].sponsor;
            if (current == address(0)) {
                return address(0);
            }
        }

        return current;
    }

    function getUserDepth(address user) external view returns (uint256) {
        uint256 depth = 0;
        address current = user;

        while (users[current].sponsor != address(0)) {
            depth++;
            current = users[current].sponsor;
        }

        return depth;
    }

    function getAllCirclePurchaseHistory(
        address user,
        Package pkg
    ) public view returns (Circle[] memory) {
        return users[user].circles[pkg];
    }
}
