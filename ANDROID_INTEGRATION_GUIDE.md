# Hướng dẫn tích hợp Flutter CC CD Module vào Android Kotlin Project

## 📋 Tổng quan kiến trúc

```
┌─────────────────┐
│  Project B      │
│  (Android)      │
│                 │
│  UI Layer       │
│  - Input form   │
│  - Result display│
└────────┬────────┘
         │ Method Channel
         │ (docNumber, dob, doe, can)
         ▼
┌─────────────────┐
│  Project A      │
│  (Flutter)      │
│                 │
│  Business Logic │
│  - NFC Scan     │
│  - Data parsing │
│  - DG extraction│
└────────┬────────┘
         │ Returns JSON
         │ (DG1, DG2, DG3...)
         ▼
┌─────────────────┐
│  Project B      │
│  Display result │
└─────────────────┘
```

---

## 🔧 Phần 1: Cấu hình Project A (Flutter)

### 1.1 Build Flutter thành AAR

```bash
cd /path/to/my_cccd_module

# Build release AAR
flutter build aar --release

# Output sẽ ở:
# build/host/outputs/repo/com/example/flutter_local_release/1.0.0/flutter_local_release-1.0.0.aar
```

### 1.2 Kiểm tra Platform Channel

Đã được cấu hình trong `lib/main.dart`:
- **Channel name**: `com.mta.pos/nfc`
- **Method**: `startScan`
- **Arguments**: 
  ```dart
  {
    'docNumber': String,
    'dob': String,        // Format: MM/DD/YYYY
    'doe': String,        // Format: MM/DD/YYYY
    'can': String?,       // Optional, 6 digits
    'isPACE': bool        // true if using PACE
  }
  ```

---

## 🏗️ Phần 2: Tích hợp vào Project B (Android Kotlin)

### 2.1 Thêm Flutter module vào Project B

**File: `settings.gradle`** (root project)
```gradle
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        
        // Add Flutter module repository
        maven {
            url '/path/to/my_cccd_module/build/host/outputs/repo'
        }
    }
}

rootProject.name = "YourProjectB"
include ':app'
```

**File: `app/build.gradle`**
```gradle
plugins {
    id 'com.android.application'
    id 'org.jetbrains.kotlin.android'
}

android {
    namespace 'com.yourcompany.projectb'
    compileSdk 34

    defaultConfig {
        applicationId "com.yourcompany.projectb"
        minSdk 24  // Flutter requires API 21+
        targetSdk 34
        versionCode 1
        versionName "1.0"

        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            minifyEnabled false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
    
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
    
    kotlinOptions {
        jvmTarget = '1.8'
    }
}

dependencies {
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'androidx.appcompat:appcompat:1.6.1'
    
    // Add Flutter dependency
    implementation 'com.example:flutter_local_release:1.0.0@aar'
    implementation 'io.flutter:flutter_embedding_release:1.0.0'
    
    // Optional: If you need lifecycle support
    implementation 'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0'
}
```

---

### 2.2 Tạo Wrapper Class cho Scanner

**File: `MrzScannerWrapper.kt`**
```kotlin
package com.yourcompany.projectb.scanner

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Wrapper để gọi Flutter CC CD Scanner từ Kotlin
 */
class MrzScannerWrapper(private val context: Context) {
    
    private var flutterEngine: FlutterEngine? = null
    private var methodChannel: MethodChannel? = null
    
    companion object {
        private const val CHANNEL_NAME = "com.mta.pos/nfc"
    }
    
    /**
     * Khởi tạo Flutter Engine (gọi 1 lần duy nhất)
     */
    fun initialize() {
        if (flutterEngine != null) return
        
        flutterEngine = FlutterEngine(context)
        
        // Execute Dart entrypoint
        flutterEngine?.dartExecutor?.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        
        // Setup method channel
        methodChannel = MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL_NAME)
    }
    
    /**
     * Giải phóng resources
     */
    fun destroy() {
        flutterEngine?.destroy()
        flutterEngine = null
        methodChannel = null
    }
    
    /**
     * Thực hiện scan NFC với thông tin đầu vào
     * 
     * @param docNumber Số CCCD/Passport
     * @param dob Date of Birth (MM/DD/YYYY)
     * @param doe Date of Expiry (MM/DD/YYYY)
     * @param can CAN number (6 digits, optional)
     * @param isPACE Sử dụng PACE protocol (default: false)
     * @return JSON chứa dữ liệu từ chip NFC
     */
    suspend fun scanPassport(
        docNumber: String,
        dob: String,
        doe: String,
        can: String? = null,
        isPACE: Boolean = false
    ): PassportScanResult = suspendCancellableCoroutine { continuation ->
        
        // Ensure engine is initialized
        if (flutterEngine == null) {
            initializationError("Flutter engine not initialized")
            return@suspendCancellableCoroutine
        }
        
        // Prepare arguments
        val args = mapOf(
            "docNumber" to docNumber,
            "dob" to dob,
            "doe" to doe,
            "can" to can,
            "isPACE" to isPACE
        )
        
        println("🚀 Starting scan with args: $args")
        
        methodChannel?.invokeMethod("startScan", args, object : MethodChannel.Result {
            override fun success(result: Any?) {
                println("✅ Scan successful")
                try {
                    val jsonResult = JSONObject(result as String)
                    val passportData = parseScanResult(jsonResult)
                    continuation.resume(passportData)
                } catch (e: Exception) {
                    continuation.resumeWithException(e)
                }
            }
            
            override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
                println("❌ Scan error: $errorCode - $errorMessage")
                continuation.resumeWithException(
                    ScannerException(errorCode ?: "UNKNOWN", errorMessage ?: "Unknown error")
                )
            }
            
            override fun notImplemented() {
                println("⚠️ Method not implemented")
                continuation.resumeWithException(
                    ScannerException("NOT_IMPLEMENTED", "startScan method not implemented")
                )
            }
        })
        
        // Handle coroutine cancellation
        continuation.invokeOnCancellation {
            println("⛔ Scan cancelled")
        }
    }
    
    /**
     * Parse kết quả scan từ Flutter
     */
    private fun parseScanResult(json: JSONObject): PassportScanResult {
        return PassportScanResult(
            isPACE = json.optBoolean("isPACE", false),
            isDBA = json.optBoolean("isDBA", false),
            cardAccess = json.optString("cardAccess", null),
            cardSecurity = json.optString("cardSecurity", null),
            com = json.optString("com", null),
            dg1 = json.optJSONObject("dg1")?.let { parseDG1(it) },
            dg2Base64 = json.optString("dg2", null),
            dg3 = json.optString("dg3", null),
            dg4 = json.optString("dg4", null),
            dg5 = json.optString("dg5", null),
            dg6 = json.optString("dg6", null),
            dg7 = json.optString("dg7", null),
            dg8 = json.optString("dg8", null),
            dg9 = json.optString("dg9", null),
            dg10 = json.optString("dg10", null),
            dg11 = json.optString("dg11", null),
            dg12 = json.optString("dg12", null),
            dg13 = json.optString("dg13", null),
            dg14 = json.optString("dg14", null),
            dg15 = json.optString("dg15", null),
            dg16 = json.optString("dg16", null),
            aaSignature = json.optString("aaSignature", null),
            sodBase64 = json.optString("sod", null)
        )
    }
    
    /**
     * Parse DG1 data (MRZ information)
     */
    private fun parseDG1(json: JSONObject): DG1Data {
        return DG1Data(
            version = json.optString("version"),
            documentCode = json.optString("documentCode"),
            documentNumber = json.optString("documentNumber"),
            country = json.optString("country"),
            nationality = json.optString("nationality"),
            firstName = json.optString("firstName"),
            lastName = json.optString("lastName"),
            gender = json.optString("gender"),
            dateOfBirth = json.optString("dateOfBirth"),
            dateOfExpiry = json.optString("dateOfExpiry"),
            optionalData = json.optString("optionalData"),
            optionalData2 = json.optString("optionalData2")
        )
    }
    
    private fun initializationError(message: String) {
        throw ScannerException("INIT_ERROR", message)
    }
}

/**
 * Kết quả scan từ chip NFC
 */
data class PassportScanResult(
    val isPACE: Boolean,
    val isDBA: Boolean,
    val cardAccess: String?,
    val cardSecurity: String?,
    val com: String?,
    val dg1: DG1Data?,
    val dg2Base64: String?,      // Face image
    val dg3: String?,
    val dg4: String?,
    val dg5: String?,
    val dg6: String?,
    val dg7: String?,
    val dg8: String?,
    val dg9: String?,
    val dg10: String?,
    val dg11: String?,
    val dg12: String?,
    val dg13: String?,
    val dg14: String?,
    val dg15: String?,
    val dg16: String?,
    val aaSignature: String?,
    val sodBase64: String?
)

/**
 * Dữ liệu DG1 - MRZ information
 */
data class DG1Data(
    val version: String?,
    val documentCode: String?,
    val documentNumber: String?,
    val country: String?,
    val nationality: String?,
    val firstName: String?,
    val lastName: String?,
    val gender: String?,
    val dateOfBirth: String?,      // MM/DD/YYYY
    val dateOfExpiry: String?,     // MM/DD/YYYY
    val optionalData: String?,
    val optionalData2: String?
)

/**
 * Exception khi scan
 */
class ScannerException(val code: String, message: String) : Exception(message)
```

---

### 2.3 Sử dụng trong Activity/Fragment

**File: `MainActivity.kt`**
```kotlin
package com.yourcompany.projectb

import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.yourcompany.projectb.databinding.ActivityMainBinding
import com.yourcompany.projectb.scanner.MrzScannerWrapper
import com.yourcompany.projectb.scanner.ScannerException
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    
    private lateinit var binding: ActivityMainBinding
    private lateinit var scannerWrapper: MrzScannerWrapper
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        // Initialize scanner wrapper
        scannerWrapper = MrzScannerWrapper(this)
        scannerWrapper.initialize()
        
        setupUI()
    }
    
    private fun setupUI() {
        // Example: Pre-fill with test data
        binding.etDocNumber.setText("097003207")
        binding.etDob.setText("08/07/1997")
        binding.etDoe.setText("08/07/2037")
        binding.etCan.setText("003207")
        
        binding.btnScan.setOnClickListener {
            performScan()
        }
    }
    
    private fun performScan() {
        val docNumber = binding.etDocNumber.text.toString().trim()
        val dob = binding.etDob.text.toString().trim()
        val doe = binding.etDoe.text.toString().trim()
        val can = binding.etCan.text.toString().trim()
        
        // Validate input
        if (docNumber.isEmpty()) {
            binding.etDocNumber.error = "Please enter document number"
            return
        }
        
        if (dob.isEmpty()) {
            binding.etDob.error = "Please enter date of birth"
            return
        }
        
        if (doe.isEmpty()) {
            binding.etDoe.error = "Please enter date of expiry"
            return
        }
        
        // Show loading
        setLoading(true)
        
        // Perform scan
        lifecycleScope.launch {
            try {
                Log.d("Scanner", "Starting NFC scan...")
                
                val result = scannerWrapper.scanPassport(
                    docNumber = docNumber,
                    dob = dob,
                    doe = doe,
                    can = if (can.isNotEmpty()) can else null,
                    isPACE = binding.checkBoxPACE.isChecked
                )
                
                Log.d("Scanner", "Scan completed successfully!")
                
                // Display result
                displayScanResult(result)
                
            } catch (e: ScannerException) {
                Log.e("Scanner", "Scan error: ${e.code} - ${e.message}")
                showError("Scan failed: ${e.message}")
            } catch (e: Exception) {
                Log.e("Scanner", "Unexpected error", e)
                showError("Unexpected error: ${e.message}")
            } finally {
                setLoading(false)
            }
        }
    }
    
    private fun displayScanResult(result: PassportScanResult) {
        val sb = StringBuilder()
        
        sb.appendLine("=== SCAN RESULT ===")
        sb.appendLine("Protocol: ${if (result.isPACE) "PACE" else "BAC"}")
        sb.appendLine("Key Type: ${if (result.isDBA) "DBA" else "CAN"}")
        sb.appendLine()
        
        // DG1 - MRZ Data
        result.dg1?.let { dg1 ->
            sb.appendLine("=== DG1 - MRZ DATA ===")
            sb.appendLine("Document No.: ${dg1.documentNumber}")
            sb.appendLine("Name: ${dg1.lastName} ${dg1.firstName}")
            sb.appendLine("DOB: ${dg1.dateOfBirth}")
            sb.appendLine("Expiry: ${dg1.dateOfExpiry}")
            sb.appendLine("Nationality: ${dg1.nationality}")
            sb.appendLine("Gender: ${dg1.gender}")
            sb.appendLine()
        }
        
        // DG2 - Face Image
        if (result.dg2Base64 != null) {
            sb.appendLine("✅ DG2 - Face image available (${result.dg2Base64.length} chars)")
            // You can decode and display the image here
            // val imageBytes = Base64.decode(result.dg2Base64, Base64.DEFAULT)
            // binding.ivFace.setImageBitmap(BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size))
        }
        
        // Other DGs
        sb.appendLine()
        sb.appendLine("=== OTHER DATA GROUPS ===")
        if (result.cardAccess != null) sb.appendLine("✅ CardAccess")
        if (result.cardSecurity != null) sb.appendLine("✅ CardSecurity")
        if (result.com != null) sb.appendLine("✅ COM")
        if (result.dg3 != null) sb.appendLine("✅ DG3")
        if (result.dg5 != null) sb.appendLine("✅ DG5")
        if (result.dg13 != null) sb.appendLine("✅ DG13")
        if (result.dg15 != null) sb.appendLine("✅ DG15")
        if (result.aaSignature != null) sb.appendLine("✅ AA Signature")
        if (result.sodBase64 != null) sb.appendLine("✅ SOD")
        
        binding.tvResult.text = sb.toString()
    }
    
    private fun setLoading(isLoading: Boolean) {
        binding.btnScan.isEnabled = !isLoading
        binding.progressBar.visibility = if (isLoading) View.VISIBLE else View.GONE
        
        if (isLoading) {
            binding.tvStatus.text = "Scanning... Hold phone near passport"
        } else {
            binding.tvStatus.text = "Ready to scan"
        }
    }
    
    private fun showError(message: String) {
        binding.tvResult.text = "❌ Error: $message"
    }
    
    override fun onDestroy() {
        super.onDestroy()
        scannerWrapper.destroy()
    }
}
```

---

### 2.4 Layout XML

**File: `res/layout/activity_main.xml`**
```xml
<?xml version="1.0" encoding="utf-8"?>
<ScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:padding="16dp">

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="vertical">

        <!-- Input Section -->
        <com.google.android.material.card.MaterialCardView
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            app:cardElevation="4dp"
            app:cardCornerRadius="8dp"
            android:layout_marginBottom="16dp">

            <LinearLayout
                android:layout_width="match_parent"
                android:layout_height="wrap_content"
                android:orientation="vertical"
                android:padding="16dp">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="Passport/CCCD Information"
                    android:textSize="18sp"
                    android:textStyle="bold"
                    android:layout_marginBottom="16dp"/>

                <com.google.android.material.textfield.TextInputLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:hint="Document Number"
                    style="@style/Widget.MaterialComponents.TextInputLayout.OutlinedBox">

                    <com.google.android.material.textfield.TextInputEditText
                        android:id="@+id/etDocNumber"
                        android:layout_width="match_parent"
                        android:layout_height="wrap_content"
                        android:inputType="textCapCharacters"/>
                </com.google.android.material.textfield.TextInputLayout>

                <com.google.android.material.textfield.TextInputLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:hint="Date of Birth (MM/DD/YYYY)"
                    android:layout_marginTop="12dp"
                    style="@style/Widget.MaterialComponents.TextInputLayout.OutlinedBox">

                    <com.google.android.material.textfield.TextInputEditText
                        android:id="@+id/etDob"
                        android:layout_width="match_parent"
                        android:layout_height="wrap_content"
                        android:inputType="date"/>
                </com.google.android.material.textfield.TextInputLayout>

                <com.google.android.material.textfield.TextInputLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:hint="Date of Expiry (MM/DD/YYYY)"
                    android:layout_marginTop="12dp"
                    style="@style/Widget.MaterialComponents.TextInputLayout.OutlinedBox">

                    <com.google.android.material.textfield.TextInputEditText
                        android:id="@+id/etDoe"
                        android:layout_width="match_parent"
                        android:layout_height="wrap_content"
                        android:inputType="date"/>
                </com.google.android.material.textfield.TextInputLayout>

                <com.google.android.material.textfield.TextInputLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:hint="CAN Number (6 digits, optional)"
                    android:layout_marginTop="12dp"
                    style="@style/Widget.MaterialComponents.TextInputLayout.OutlinedBox">

                    <com.google.android.material.textfield.TextInputEditText
                        android:id="@+id/etCan"
                        android:layout_width="match_parent"
                        android:layout_height="wrap_content"
                        android:inputType="number"
                        android:maxLength="6"/>
                </com.google.android.material.textfield.TextInputLayout>

                <CheckBox
                    android:id="@+id/checkBoxPACE"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="Use PACE protocol"
                    android:layout_marginTop="12dp"/>

            </LinearLayout>
        </com.google.android.material.card.MaterialCardView>

        <!-- Scan Button -->
        <Button
            android:id="@+id/btnScan"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:text="📱 Scan Passport with NFC"
            android:textSize="16sp"
            android:padding="12dp"
            android:layout_marginBottom="16dp"/>

        <!-- Status -->
        <TextView
            android:id="@+id/tvStatus"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:text="Ready to scan"
            android:textAlignment="center"
            android:textSize="14sp"
            android:layout_marginBottom="8dp"/>

        <!-- Progress Bar -->
        <ProgressBar
            android:id="@+id/progressBar"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_gravity="center"
            android:visibility="gone"/>

        <!-- Result Section -->
        <com.google.android.material.card.MaterialCardView
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            app:cardElevation="4dp"
            app:cardCornerRadius="8dp">

            <TextView
                android:id="@+id/tvResult"
                android:layout_width="match_parent"
                android:layout_height="wrap_content"
                android:padding="16dp"
                android:textSize="14sp"
                android:fontFamily="monospace"
                android:text="Results will appear here..."/>
        </com.google.android.material.card.MaterialCardView>

    </LinearLayout>
</ScrollView>
```

---

## 🧪 Phần 3: Testing

### 3.1 Test case đơn giản

```kotlin
@Test
fun testScanPassport() = runBlocking {
    val wrapper = MrzScannerWrapper(ApplicationProvider.getApplicationContext())
    wrapper.initialize()
    
    try {
        val result = wrapper.scanPassport(
            docNumber = "097003207",
            dob = "08/07/1997",
            doe = "08/07/2037",
            can = "003207",
            isPACE = false
        )
        
        assertNotNull(result)
        assertNotNull(result.dg1)
        assertEquals("097003207", result.dg1?.documentNumber)
        
    } finally {
        wrapper.destroy()
    }
}
```

---

## ⚠️ Lưu ý quan trọng

### 1. Permissions
Thêm vào `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.NFC" />
<uses-feature android:name="android.hardware.nfc" android:required="true" />
```

### 2. Proguard Rules
Thêm vào `proguard-rules.pro`:
```proguard
# Keep Flutter classes
-keep class io.flutter.** { *; }
-keep class com.example.** { *; }
```

### 3. Date Format
- Flutter dùng format: `MM/DD/YYYY`
- Kotlin cần validate input trước khi gửi

### 4. Lifecycle Management
- Gọi `initialize()` trong `onCreate()`
- Gọi `destroy()` trong `onDestroy()`
- Không tạo nhiều instance của `FlutterEngine`

### 5. Performance
- Flutter engine khởi động mất ~500ms-1s
- Nên keep engine alive nếu cần scan nhiều lần
- Sử dụng coroutine scope phù hợp

---

## 🎯 Ưu điểm của giải pháp này

✅ **Tái sử dụng 100% logic Flutter**  
✅ **Project B chỉ lo UI và input**  
✅ **Không cần rewrite NFC logic sang Kotlin**  
✅ **Dễ dàng maintain và update**  
✅ **Hoạt động trên cả Android và iOS (nếu cần)**  

---

## 📞 Troubleshooting

**Q: Flutter engine không khởi động?**  
A: Kiểm tra path đến AAR file trong `settings.gradle`

**Q: Method channel bị timeout?**  
A: Đảm bảo Flutter app đã execute Dart entrypoint

**Q: NFC không hoạt động?**  
A: Kiểm tra permissions và NFC hardware availability

**Q: Dữ liệu trả về bị null?**  
A: Check logcat để xem lỗi từ Flutter side

---

## 📚 Tham khảo thêm

- [Flutter Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Add Flutter to Existing App](https://docs.flutter.dev/add-to-app)
- [ML Kit Text Recognition](https://developers.google.com/ml-kit/vision/text-recognition)
