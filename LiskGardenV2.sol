// LiskGardenV2.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// Pastikan file GardenToken.sol sudah ada dan dapat di-import
import "./GardenToken.sol";

contract LiskGardenV2 is ERC721, Ownable, ERC721URIStorage {
    using SafeMath for uint256;
    using Strings for uint256;

    IERC20 public gdnToken;
    
    // --- ENUMS dari LiskGarden.sol ---
    enum GrowthStage { SEED, SPROUT, GROWING, BLOOMING }
    // --- Atribut Tanaman NFT ---
    enum ItemType { FERTILIZER, WATER }

    // --- HARGA DAN REWARD (18 desimal) ---
    uint256 public constant ETH_ENTRY_FEE = 100000000000000; // 0.0001 ETH
    uint256 public constant INITIAL_GDN_GIVEAWAY = 100 * 10**18; // 100 GDN
    uint256 public constant REWARD_GDN_AMOUNT = 10 * 10**18; // 10 GDN
    
    // --- ITEM PRICE ---
    uint256 public constant PLANT_NFT_COST = 50 * 10**18; // 50 GDN
    uint256 public constant FERTILIZER_COST = 15 * 10**18; // 15 GDN
    uint256 public constant WATER_COST = 10 * 10**18; // 10 GDN

    // --- BATAS PENGGUNAAN PER SIKLUS (V2 Logic) ---
    uint256 public constant MAX_CYCLE_USE = 2; // Batas penggunaan (2x)
    uint256 public constant RESET_INTERVAL = 2 minutes; // Interval reset kuota: 2 menit (120 detik)
    
    // --- KONSTANTA PERTUMBUHAN & DEPLESI (V1 Logic) ---
    uint256 public constant STAGE_DURATION = 2 minutes; // Durasi per stage
    uint256 public constant WATER_DEPLETION_TIME = 30 seconds; // Interval pengurangan air
    uint8 public constant WATER_DEPLETION_RATE = 2; // Kecepatan pengurangan WaterLevel (per 30 detik)

    // --- METADATA IPFS CONFIG ---
    // Ganti dengan Base Gateway Pinata Anda
    string public basePinataGateway = "https://black-effective-camel-513.mypinata.cloud/ipfs/bafkreihyv65zkyglmrp6fissffqaq72zhu4cqnuzxxd55ams6zbchcsnfu";

    uint256 private _nextPlantId = 1;

    struct PlantData {
        // V2 (Progress dan Kuota)
        uint256 progress;
        uint256 lastWaterResetTime; 
        uint256 waterCount;
        uint256 lastFertilizerResetTime; 
        uint256 fertilizerCount;
        
        // V1 (Stage dan Depletion)
        GrowthStage stage; // Tahap pertumbuhan
        uint256 plantedDate; // Waktu pertama kali ditanam (untuk stage)
        uint256 lastWatered; // Waktu terakhir disiram (untuk depletion)
        uint8 waterLevel; // Level air (0-100)
        bool isDead; // Status kematian
    }
    mapping(uint256 => PlantData) public plants;
    
    // --- Events (V1 dan V2) ---
    event GDNBought(address indexed to, uint256 amount);
    event PlantPurchased(uint256 indexed plantId, address indexed buyer);
    event ProgressUpdated(uint256 indexed plantId, address indexed by, uint256 newProgress);
    event RewardClaimed(uint256 indexed plantId, address indexed owner, uint256 amount);
    event PlantDied(uint256 indexed plantId);
    event StageAdvanced(uint256 indexed plantId, GrowthStage newStage);

    // --- Constructor ---
    constructor(address _gdnTokenAddress) ERC721("Lisk Garden Plant", "LGP") Ownable(msg.sender) {
        gdnToken = IERC20(_gdnTokenAddress);
    }


    // --- Fungsi untuk IPFS ---
    // Fungsi untuk Owner mengubah Base Gateway Pinata
    function setBasePinataGateway(string memory newBase) public onlyOwner {
        basePinataGateway = newBase;
    }

    // Menggabungkan Base Gateway Pinata dengan URI yang tersimpan
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage) // <-- Penting untuk override
        returns (string memory)
    {
        // Pengecekan token ada (ownerOf akan revert jika tidak ada)
        require(ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");
        
        string memory storedURI = super.tokenURI(tokenId); // Ambil URI yang tersimpan (misal: "1.json")
        
        // Jika URI kosong, berikan URI dasar Pinata saja
        if (bytes(storedURI).length == 0) {
            return basePinataGateway;
        }

        // Gabungkan Base Gateway dengan URI yang tersimpan
        return string(abi.encodePacked(basePinataGateway, storedURI));
    }
    
    // Fungsi internal untuk memanggil override super ERC721URIStorage
    function _baseURI() internal pure override(ERC721) returns (string memory) {
        return "";
    }

    // --- Fungsi dari V1 Logic ---

    // 1. Hitung Level Air Saat Ini
    function calculateWaterLevel(uint256 plantId) public view returns (uint8) {
        PlantData storage plant = plants[plantId];
        
        if (plant.isDead || plant.waterLevel == 0) {
            return 0;
        }

        uint256 timeSinceWatered = block.timestamp.sub(plant.lastWatered);
        uint256 depletionIntervals = timeSinceWatered.div(WATER_DEPLETION_TIME);
        uint256 waterLost = depletionIntervals.mul(WATER_DEPLETION_RATE);

        if (waterLost >= plant.waterLevel) {
            return 0;
        }

        // Konversi plant.waterLevel (uint8) ke uint256 agar bisa menggunakan SafeMath.sub
        uint256 currentLevel = uint256(plant.waterLevel).sub(waterLost);

        // Pastikan hasil akhir dikembalikan sebagai uint8
        return uint8(currentLevel);
    }
    
    // 2. Perbarui Level Air dan Tahap Pertumbuhan (Dipanggil di awal setiap aksi)
    function updateWaterAndStage(uint256 plantId) internal {
        PlantData storage plant = plants[plantId];
        
        // A. Update Water Level dan Cek Kematian
        uint8 currentWater = calculateWaterLevel(plantId);
        plant.waterLevel = currentWater;

        // Cek jika mati sekarang (dan belum mati sebelumnya)
        if (currentWater == 0 && !plant.isDead) {
            plant.isDead = true;
            emit PlantDied(plantId);
        }
        
        // Jika sudah mati, atau sekarang mati, tahap tidak bisa berubah.
        if (plant.isDead) {
            return;
        }
        
        // B. Update Growth Stage
        uint256 timeSincePlanted = block.timestamp.sub(plant.plantedDate);
        GrowthStage oldStage = plant.stage;
        
        // Logika stage dari V1: SEED(0), SPROUT(1), GROWING(2), BLOOMING(3)
        if (plant.stage == GrowthStage.GROWING && timeSincePlanted >= 3 * STAGE_DURATION) {
            plant.stage = GrowthStage.BLOOMING;
        } else if (plant.stage == GrowthStage.SPROUT && timeSincePlanted >= 2 * STAGE_DURATION) {
            plant.stage = GrowthStage.GROWING;
        } else if (plant.stage == GrowthStage.SEED && timeSincePlanted >= STAGE_DURATION) {
            plant.stage = GrowthStage.SPROUT;
        }

        if (plant.stage != oldStage) {
            emit StageAdvanced(plantId, plant.stage);
        }
    }

    // --- Fungsi Utama Game ---

    function buyGDN() external payable {
        require(msg.value == ETH_ENTRY_FEE, "Must pay 0.0001 ETH.");
        address user = msg.sender;
        
        // Mint GDN (100 GDN)
        GardenToken(address(gdnToken)).mint(user, INITIAL_GDN_GIVEAWAY);
        emit GDNBought(user, INITIAL_GDN_GIVEAWAY);
    }
    
function buyPlantNFT() external {
        address buyer = msg.sender;
        uint256 newPlantId = _nextPlantId;
        
        // 1. Tarik Biaya GDN (50 GDN) dan Burn
        bool success = gdnToken.transferFrom(buyer, address(this), PLANT_NFT_COST);
        require(success, "GDN transfer failed. Check allowance/balance for 50 GDN.");
        GardenToken(address(gdnToken)).burn(PLANT_NFT_COST);

        // 2. Mint NFT (ERC-721)
        _safeMint(buyer, newPlantId);
        
        // 3. SET METADATA URI (BARU)
        // Kita menetapkan URI relatif (misal "1.json", "2.json", dst.)
        _setTokenURI(newPlantId, string(abi.encodePacked(newPlantId.toString(), ".json"))); // <-- BARIS BARU
        
        // 4. Set data mutabel dan inisialisasi V1 logic
        plants[newPlantId] = PlantData({
            progress: 0,
            lastWaterResetTime: 0, 
            waterCount: 0,
            lastFertilizerResetTime: 0, 
            fertilizerCount: 0,
            // V1 Initialization
            stage: GrowthStage.SEED,
            plantedDate: block.timestamp,
            lastWatered: block.timestamp,
            waterLevel: 100,
            isDead: false
        });
        
        _nextPlantId++;
        emit PlantPurchased(newPlantId, buyer);
    }

    function useItem(uint256 plantId, ItemType item) external {
        address owner = ownerOf(plantId);
        require(owner == msg.sender, "Must own the plant to use item on it.");
        
        // Update status air dan tahap (mencegah tanaman mati)
        updateWaterAndStage(plantId); 
        
        // Cek status setelah update
        require(!plants[plantId].isDead, "Plant is dead and cannot be cared for. Use a resurrection item or act faster.");
        require(plants[plantId].progress < 100, "Plant is already 100%. Claim reward first.");

        uint256 cost;
        uint256 progressIncrease;
        PlantData storage plant = plants[plantId];
        uint256 currentTime = block.timestamp;
        
        if (item == ItemType.FERTILIZER) {
            cost = FERTILIZER_COST;
            progressIncrease = 20;
            
            if (currentTime >= plant.lastFertilizerResetTime.add(RESET_INTERVAL)) {
                plant.lastFertilizerResetTime = currentTime;
                plant.fertilizerCount = 0;
            }
            require(plant.fertilizerCount < MAX_CYCLE_USE, "Fertilizer limit (2x) reached for this cycle.");
            plant.fertilizerCount = plant.fertilizerCount.add(1);

        } else if (item == ItemType.WATER) {
            cost = WATER_COST;
            progressIncrease = 15;
            
            if (currentTime >= plant.lastWaterResetTime.add(RESET_INTERVAL)) {
                plant.lastWaterResetTime = currentTime;
                plant.waterCount = 0;
            }
            require(plant.waterCount < MAX_CYCLE_USE, "Water limit (2x) reached for this cycle.");
            plant.waterCount = plant.waterCount.add(1);
            
            // Tambahan Logic V1: Water me-reset waterLevel dan lastWatered
            plant.waterLevel = 100;
            plant.lastWatered = currentTime;
        } else {
            revert("Invalid item type.");
        }

        // 1. Tarik biaya GDN dari pengguna dan Burn
        // Perbaikan: Deklarasi variabel `successTransfer`
        bool successTransfer = gdnToken.transferFrom(msg.sender, address(this), cost);
        require(successTransfer, "GDN transfer failed. Check allowance/balance.");

        GardenToken(address(gdnToken)).burn(cost);

        // 2. Update Progress
        plant.progress = plant.progress.add(progressIncrease);
        if (plant.progress > 100) {
            plant.progress = 100;
        }

        emit ProgressUpdated(plantId, msg.sender, plant.progress);
    }

    function careForOtherPlant(uint256 plantId) external {
        address plantOwner = ownerOf(plantId);
        
        // Update status air dan tahap
        updateWaterAndStage(plantId); 
        
        require(plantOwner != msg.sender, "Cannot care for your own plant using this function.");
        require(!plants[plantId].isDead, "Plant is dead and cannot be cared for.");
        require(plants[plantId].progress < 100, "Plant is already 100%.");

        // Penambahan progress yang sangat kecil (+1%)
        uint256 progressIncrease = 1;
        
        // Update Progress
        plants[plantId].progress = plants[plantId].progress.add(progressIncrease);
        if (plants[plantId].progress > 100) {
            plants[plantId].progress = 100;
        }

        emit ProgressUpdated(plantId, msg.sender, plants[plantId].progress);
    }

    function claimReward(uint256 plantId) external {
        address owner = ownerOf(plantId);
        require(owner == msg.sender, "Only plant owner can claim reward.");
        
        // Update status air dan tahap (penting untuk cek BLOOMING dan isDead)
        updateWaterAndStage(plantId); 
        
        require(!plants[plantId].isDead, "Plant is dead and cannot claim reward.");
        
        // Cek progres MINIMUM V2
        require(plants[plantId].progress >= 100, "Plant progress must be 100% or more.");
        // Cek tahap MINIMUM V1
        require(plants[plantId].stage == GrowthStage.BLOOMING, "Plant must be BLOOMING stage (fully grown by time) to claim reward.");

        // Memberikan Reward (Mint GDN baru: 10 GDN)
        GardenToken(address(gdnToken)).mint(owner, REWARD_GDN_AMOUNT);
        
        // Reset progress, stage, dan plantedDate untuk siklus baru
        plants[plantId].progress = 0;
        plants[plantId].stage = GrowthStage.SEED;
        plants[plantId].plantedDate = block.timestamp;

        emit RewardClaimed(plantId, owner, REWARD_GDN_AMOUNT);
    }
    
    // --- Fungsi Helper (View) ---
    
    // Fungsi view yang lebih komprehensif untuk melihat status tanaman
    function getPlantFullStatus(uint256 plantId) public view returns (
        uint256 progress,
        GrowthStage stage,
        uint8 currentWaterLevel,
        bool isDead,
        uint256 waterCountInCycle,
        uint256 fertilizerCountInCycle,
        uint256 waterTimeRemaining, // Waktu tersisa (detik) untuk reset kuota air
        uint256 fertilizerTimeRemaining // Waktu tersisa (detik) untuk reset kuota pupuk
    ) {
        PlantData memory data = plants[plantId];
        uint256 currentTime = block.timestamp;
        
        // 1. Hitung Water Level Aktual
        currentWaterLevel = calculateWaterLevel(plantId);

        // 2. Cek reset kuota Air (V2 Logic)
        uint256 waterCount = data.waterCount;
        waterTimeRemaining = 0; 
        if (currentTime >= data.lastWaterResetTime.add(RESET_INTERVAL)) {
            waterCount = 0;
        } else {
            waterTimeRemaining = data.lastWaterResetTime.add(RESET_INTERVAL).sub(currentTime);
        }

        // 3. Cek reset kuota Pupuk (V2 Logic)
        uint256 fertilizerCount = data.fertilizerCount;
        fertilizerTimeRemaining = 0; 
        if (currentTime >= data.lastFertilizerResetTime.add(RESET_INTERVAL)) {
            fertilizerCount = 0;
        } else {
            fertilizerTimeRemaining = data.lastFertilizerResetTime.add(RESET_INTERVAL).sub(currentTime);
        }

        // 4. Assignment hasil akhir
        progress = data.progress;
        stage = data.stage;
        // Gunakan isDead dari data (yang akan menjadi true saat air 0)
        isDead = data.isDead; 
        waterCountInCycle = waterCount;
        fertilizerCountInCycle = fertilizerCount;
    }
    
    function withdrawETH() external onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}("");
        require(success, "ETH withdrawal failed");
    }

    // Override _approve, _transfer, dan _safeTransfer di ERC721URIStorage
    // Ini diperlukan jika Anda menggunakan OpenZeppelin v5.x
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }
    
    // Perlu juga me-override supportsInterface
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
