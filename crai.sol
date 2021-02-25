pragma solidity 0.5.17;

contract OracleRelayer {
    function redemptionPrice() public returns (uint);
}

contract CoinLike {
    function transferFrom(address,address,uint) external returns (bool);
    function transfer(address,uint) external returns (bool);
    function balanceOf(address) external returns (uint);
}

contract CRAI {
    OracleRelayer public constant Oracle = OracleRelayer(0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851);
    CoinLike      public constant RAI    = CoinLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);

        // --- ERC20 Data ---
    string  public constant name     = "Crai";
    string  public constant symbol   = "CRAI";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;

    mapping (address => uint)                      public balanceOfUnderlying;
    mapping (address => mapping (address => uint)) public allowance;
    mapping (address => uint)                      public nonces;

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);

    // --- Math ---
    uint constant RAY = 10 ** 27;
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rmul(uint x, uint y) internal pure returns (uint z) {
        // always rounds down
        z = mul(x, y) / RAY;
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        // always rounds down
        z = mul(x, RAY) / y;
    }
    function rdivup(uint x, uint y) internal pure returns (uint z) {
        // always rounds up
        z = add(mul(x, RAY), sub(y, 1)) / y;
    }

     // --- EIP712 niceties ---
    bytes32 public DOMAIN_SEPARATOR;
    // bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb;

    constructor() public {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            1,
            address(this)
        ));
    }

    function totalSupply() external returns (uint wad) {
        uint rp = Oracle.redemptionPrice();
        wad = rmul(rp, RAI.balanceOf(address(this)));
    }

    function balanceOf(address usr) external returns (uint wad) {
        uint rp = Oracle.redemptionPrice();
        wad = rmul(rp, balanceOfUnderlying[usr]);
    }

    // --- Token ---
    function transfer(address dst, uint wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
        public returns (bool)
    {
        uint rp = Oracle.redemptionPrice();
        uint amt = rdivup(wad, rp);

        require(balanceOfUnderlying[src] >= amt, "crai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad, "crai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }
        balanceOfUnderlying[src] = sub(balanceOfUnderlying[src], amt);
        balanceOfUnderlying[dst] = add(balanceOfUnderlying[dst], amt);
        emit Transfer(src, dst, wad);
        return true;
    }

    function approve(address usr, uint wad) external returns (bool) {
        allowance[msg.sender][usr] = wad;
        emit Approval(msg.sender, usr, wad);
        return true;
    }

    // wad is denominated in rai
    function join(address dst, uint wad) external {
        uint rp = Oracle.redemptionPrice();
        uint amt = rmul(wad, rp);
        balanceOfUnderlying[dst] = add(balanceOfUnderlying[dst], wad);
        RAI.transferFrom(msg.sender, address(this), wad);
        emit Transfer(address(0), dst, amt);
    }

    // wad is denominated in rai
    function exit(address src, uint wad) public {
        require(balanceOfUnderlying[src] >= wad, "crai/insufficient-balance");
        uint rp = Oracle.redemptionPrice();
        uint amt = rmul(wad, rp);
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= amt, "crai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], amt);
        }
        balanceOfUnderlying[src] = sub(balanceOfUnderlying[src], wad);
        RAI.transfer(msg.sender, wad);
        emit Transfer(src, address(0), amt);
    }

    // wad is denominated in usd
    function draw(address src, uint wad) external {
        uint rp = Oracle.redemptionPrice();
        uint amt = rdivup(wad, rp);
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad, "crai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }
        require(balanceOfUnderlying[src] >= amt, "crai/insufficient-balance");
        balanceOfUnderlying[src] = sub(balanceOfUnderlying[src], amt);
        RAI.transfer(msg.sender, amt);
        emit Transfer(src, address(0), wad);
    }

    // --- Approve by signature ---
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external
    {
        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH,
                                     holder,
                                     spender,
                                     nonce,
                                     expiry,
                                     allowed))
        ));

        require(holder != address(0), "CRAI/invalid-address-0");
        require(holder == ecrecover(digest, v, r, s), "CRAI/invalid-permit");
        require(expiry == 0 || now <= expiry, "CRAI/permit-expired");
        require(nonce == nonces[holder]++, "CRAI/invalid-nonce");
        uint256 wad = allowed ? uint256(-1) : 0;
        allowance[holder][spender] = wad;
        emit Approval(holder, spender, wad);
    }

}
