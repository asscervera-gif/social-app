package com.social.app.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Listas de difusión reales, comparado con WhatsApp -- ver
 * BroadcastListsViewModel.kt para el hallazgo completo
 * (0103_broadcast_lists.sql). Pantalla única: la lista de listas, y al
 * tocar una, sus miembros + el compositor para mandarle un mensaje real
 * de un tirón.
 */
@Composable
fun BroadcastListsScreen(viewModel: BroadcastListsViewModel = viewModel()) {
    val lists by viewModel.lists.collectAsState()
    val members by viewModel.members.collectAsState()
    val myFollowing by viewModel.myFollowing.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val sendResult by viewModel.sendResult.collectAsState()
    var selectedList by remember { mutableStateOf<BroadcastList?>(null) }
    var showNewListDialog by remember { mutableStateOf(false) }
    var newListName by remember { mutableStateOf("") }
    var showAddMember by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { viewModel.load() }

    val current = selectedList
    if (current == null) {
        Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
            Button(onClick = { showNewListDialog = true }, modifier = Modifier.fillMaxWidth()) {
                Text("+ Nueva lista de difusión")
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
            LazyColumn(modifier = Modifier.padding(top = 12.dp)) {
                items(lists) { list ->
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        onClick = {
                            selectedList = list
                            viewModel.loadMembers(list.id)
                        }
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(14.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("📢 ${list.name}")
                            IconButton(onClick = { viewModel.deleteList(list.id) }) {
                                Text("🗑")
                            }
                        }
                    }
                }
                if (lists.isEmpty()) {
                    item {
                        Text(
                            "Todavía no tienes ninguna lista de difusión.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 24.dp)
                        )
                    }
                }
            }
        }
    } else {
        Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = { selectedList = null }) { Text("‹ Listas") }
                Text(current.name, style = MaterialTheme.typography.titleMedium)
            }
            sendResult?.let {
                Text(it, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp))
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
            LazyColumn(modifier = Modifier.weight(1f).padding(top = 8.dp)) {
                items(members) { member ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(member.displayName)
                        TextButton(onClick = { viewModel.removeMember(current.id, member.id) }) { Text("Quitar") }
                    }
                }
                item {
                    OutlinedButton(onClick = { showAddMember = true }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                        Text("+ Añadir persona")
                    }
                }
            }
            Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = { Text("Mensaje para toda la lista…") },
                    modifier = Modifier.weight(1f)
                )
                Button(
                    onClick = {
                        viewModel.sendBroadcast(draft)
                        draft = ""
                    },
                    enabled = draft.isNotBlank() && members.isNotEmpty(),
                    modifier = Modifier.padding(start = 8.dp)
                ) { Text("➤") }
            }
        }
    }

    if (showNewListDialog) {
        AlertDialog(
            onDismissRequest = { showNewListDialog = false; newListName = "" },
            title = { Text("Nueva lista de difusión") },
            text = {
                OutlinedTextField(
                    value = newListName,
                    onValueChange = { newListName = it },
                    label = { Text("Nombre (p. ej. \"Amigos cercanos\")") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.createList(newListName)
                        showNewListDialog = false
                        newListName = ""
                    },
                    enabled = newListName.isNotBlank()
                ) { Text("Crear") }
            },
            dismissButton = {
                TextButton(onClick = { showNewListDialog = false; newListName = "" }) { Text("Cancelar") }
            }
        )
    }

    if (showAddMember && current != null) {
        val alreadyMemberIds = members.map { it.id }.toSet()
        AlertDialog(
            onDismissRequest = { showAddMember = false },
            title = { Text("Añadir persona") },
            text = {
                val candidates = myFollowing.filter { it.id !in alreadyMemberIds }
                if (candidates.isEmpty()) {
                    Text(
                        "No sigues a nadie más que ya no esté en la lista.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    LazyColumn {
                        items(candidates) { person ->
                            Text(
                                person.displayName,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 10.dp)
                                    .clickable {
                                        viewModel.addMember(current.id, person.id, person.displayName)
                                        showAddMember = false
                                    }
                            )
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { showAddMember = false }) { Text("Cerrar") }
            }
        )
    }
}
