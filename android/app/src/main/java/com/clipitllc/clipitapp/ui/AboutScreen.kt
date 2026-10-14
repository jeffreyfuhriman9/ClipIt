package com.clipitllc.clipitapp.ui

import android.content.Intent
import androidx.core.net.toUri
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.pm.PackageInfoCompat
import com.clipitllc.clipitapp.R
import com.clipitllc.clipitapp.ui.theme.BlueMarble
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AboutScreen(
    onNavigate: (SettingsNavigation) -> Unit,
    onBack: () -> Unit,
    onReplayTutorial: () -> Unit
) {
    val context = LocalContext.current
    val packageInfo = remember(context) { runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull() }

    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text("About", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.White,
                    titleContentColor = CosmosBlue,
                    navigationIconContentColor = CosmosBlue
                )
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color(0xFFF2F2F7)),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Surface(
                        modifier = Modifier.size(72.dp),
                        shape = RoundedCornerShape(16.dp),
                        color = Color.White,
                        shadowElevation = 8.dp
                    ) {
                        Image(
                            painter = androidx.compose.ui.res.painterResource(R.drawable.clipit_icon),
                            contentDescription = "ClipIt app icon",
                            modifier = Modifier.fillMaxSize(),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop
                        )
                    }
                    Text("ClipIt", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                    Text("Version ${packageInfo?.versionName ?: "1.0"} (${packageInfo?.let(PackageInfoCompat::getLongVersionCode) ?: 1})",
                        color = Color.Gray, style = MaterialTheme.typography.bodySmall)
                }
            }

            item { SectionHeader("Learn More") }
            item {
                AboutRow(
                    icon = Icons.Default.SmartDisplay,
                    iconColor = CrimsonBlaze,
                    label = "Rewatch App Tutorial",
                    onClick = onReplayTutorial
                )
            }
            item {
                AboutRow(
                    icon = Icons.Default.QuestionMark,
                    iconColor = BlueMarble,
                    label = "Frequently Asked Questions",
                    onClick = { onNavigate(SettingsNavigation.FAQ) }
                )
            }
            item { SectionHeader("Connect & Support") }
            item {
                AboutRow(
                    icon = Icons.Default.Star,
                    iconColor = Color(0xFFFFD700), // Gold
                    label = "Coming soon to Play Store",
                    onClick = {
                        val intent = Intent(Intent.ACTION_VIEW, "https://play.google.com".toUri())
                        context.startActivity(intent)
                    }
                )
            }
            item {
                AboutRow(
                    icon = Icons.Default.Email,
                    iconColor = Color.Green,
                    label = "Send Feedback / Support",
                    onClick = {
                        val intent = Intent(Intent.ACTION_SENDTO).apply {
                            data = "mailto:ryanjohns.clipit@gmail.com".toUri()
                        }
                        context.startActivity(intent)
                    }
                )
            }
            item {
                AboutRow(
                    icon = Icons.Default.Favorite,
                    iconColor = CrimsonBlaze,
                    label = "Note from Developers",
                    onClick = { onNavigate(SettingsNavigation.DeveloperNote) }
                )
            }

            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text("Made with ❤️ by athletes for athletes.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
                    Text("© 2026 ClipIt LLC. All rights reserved.", color = Color.Gray.copy(alpha = 0.7f), fontSize = 11.sp)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FAQScreen(onBack: () -> Unit) {
    val faqs = listOf(
        FAQItem(
            "How does ClipIt work?",
            "ClipIt works just like your phone camera except you are your own instant highlight broadcaster! When you tap the on screen 'ClipIt' button, or through our bluetooth ClipIt Button, the preceding seconds, ranging from 5s to 60s, are instantly saved into a standalone highlight clip."
        ),
        FAQItem(
            "How do I pair a the ClipIt BlueTooth Button?",
            "Ensure your Bluetooth ClipIt Button is turned on. Navigate to the Device screen and press 'Scan for ClipIt Button'. Once connected, the small button toggles recording and the larger button triggers a ClipIt highlight."
        ),
        FAQItem(
            "I'm running out of storage?",
            "Raw Original Videos use the most storage. Once you’ve saved or edited your highlights, you can safely delete the Original Video—your highlights will remain saved."
        )
    )

    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text("Frequently Asked", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color(0xFFF2F2F7))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(faqs) { faq ->
                FAQRow(faq)
            }
        }
    }
}

data class FAQItem(val question: String, val answer: String)

@Composable
fun FAQRow(faq: FAQItem) {
    var expanded by remember { mutableStateOf(false) }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = Color.White
    ) {
        Column(
            modifier = Modifier
                .clickable { expanded = !expanded }
                .padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = faq.question,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold
                )
                Icon(
                    imageVector = Icons.Default.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.rotate(if (expanded) 180f else 0f),
                    tint = BlueMarble
                )
            }
            AnimatedVisibility(visible = expanded) {
                Text(
                    text = faq.answer,
                    modifier = Modifier.padding(top = 10.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray,
                    lineHeight = 20.sp
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeveloperNoteScreen(onBack: () -> Unit) {
    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text("Developer Note", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color(0xFFF2F2F7))
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Default.FormatQuote, contentDescription = null, modifier = Modifier.size(40.dp), tint = CrimsonBlaze)
                Text("A Note from the Creators", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text("Why we built ClipIt", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
            }

            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(20.dp),
                color = Color.White,
                shadowElevation = 2.dp
            ) {
                Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("We're happy you're here! 😁", fontWeight = FontWeight.Bold)
                    Text("As two college volleyball athletes, we love filming our games and practices. However we found it difficult to find the time to rewatch the footage, extract our best moments, and keep them organized. That's why we built ClipIt.")
                    Text("ClipIt will help keep video recording organized, make sure you never miss a highlight again, and save storage space by keeping only the 'wow' moments.")
                    
                    HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                    
                    Column {
                        Text("Thank you for being part of the journey,", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
                        Text("— The ClipIt Team", color = CrimsonBlaze, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }
    }
}

@Composable
fun AboutRow(
    icon: ImageVector,
    iconColor: Color,
    label: String,
    onClick: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() },
        color = Color.White
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = iconColor)
            Text(text = label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            Spacer(modifier = Modifier.weight(1f))
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Color.LightGray, modifier = Modifier.size(16.dp))
        }
    }
}
