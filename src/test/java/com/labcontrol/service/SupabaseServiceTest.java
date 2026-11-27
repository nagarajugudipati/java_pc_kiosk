package com.labcontrol.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import junit.framework.TestCase;

import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;

public class SupabaseServiceTest extends TestCase {
    public void testDiskQueueReplaysSameEventAfterRestart() throws Exception {
        var folder = Files.createTempDirectory("kiosk-offline-test");
        var received = new LinkedBlockingQueue<JsonNode>();
        var online = new AtomicBoolean();
        var json = new ObjectMapper();
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/auth/v1/token", exchange -> {
            byte[] response = "{\"access_token\":\"token\",\"expires_in\":3600}".getBytes(StandardCharsets.UTF_8);
            try (exchange) {
                exchange.sendResponseHeaders(200, response.length);
                exchange.getResponseBody().write(response);
            }
        });
        server.createContext("/rest/v1/rpc/record_kiosk_events", exchange -> {
            try (exchange) {
                received.add(json.readTree(exchange.getRequestBody()).path("p_events").get(0));
                exchange.sendResponseHeaders(online.get() ? 204 : 503, -1);
            }
        });
        server.start();
        var url = URI.create("http://127.0.0.1:" + server.getAddress().getPort());
        SupabaseService service = null;
        try {
            service = new SupabaseService(url, "test", "kiosk@example.invalid", "test", folder);
            service.logActivity("PC-1", "Notepad", "notepad.exe", "OPENED");
            JsonNode original = received.poll(8, TimeUnit.SECONDS);
            assertNotNull(original);
            service.stopWriter();
            received.clear();
            online.set(true);
            service = new SupabaseService(url, "test", "kiosk@example.invalid", "test", folder);
            assertEquals(original, received.poll(8, TimeUnit.SECONDS));
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (directoryHasEntries(folder) && System.nanoTime() < deadline) Thread.sleep(30);
            assertFalse(directoryHasEntries(folder));
        } finally {
            if (service != null) service.stopWriter();
            server.stop(0);
            try (var files = Files.list(folder)) {
                for (var path : files.toList()) Files.deleteIfExists(path);
            }
            Files.deleteIfExists(folder);
        }
    }

    private boolean directoryHasEntries(java.nio.file.Path path) throws java.io.IOException {
        try (var files = Files.list(path)) {
            return files.findAny().isPresent();
        }
    }

    public void testQueueRetriesAndPreservesEventIdentity() throws Exception {
        ObjectMapper json = new ObjectMapper();
        BlockingQueue<JsonNode> received = new LinkedBlockingQueue<>();
        BlockingQueue<String> tokens = new LinkedBlockingQueue<>();
        AtomicInteger writes = new AtomicInteger();
        AtomicInteger signIns = new AtomicInteger();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/auth/v1/token", exchange -> {
            byte[] result = ("{\"access_token\":\"test-token-" + signIns.incrementAndGet()
                    + "\",\"expires_in\":3600}").getBytes(StandardCharsets.UTF_8);
            try (exchange) {
                exchange.sendResponseHeaders(200, result.length);
                exchange.getResponseBody().write(result);
            }
        });
        server.createContext("/rest/v1/rpc/record_kiosk_events", exchange -> {
            try (exchange) {
                int write = writes.incrementAndGet();
                tokens.add(exchange.getRequestHeaders().getFirst("Authorization"));
                if (!"return=minimal".equals(exchange.getRequestHeaders().getFirst("Prefer"))) {
                    exchange.sendResponseHeaders(400, -1);
                    return;
                }
                received.add(json.readTree(exchange.getRequestBody()).path("p_events"));
                exchange.sendResponseHeaders(write == 1 ? 503 : write == 2 ? 401 : 204, -1);
            }
        });
        server.start();
        try {
            SupabaseService service = new SupabaseService(
                    URI.create("http://127.0.0.1:" + server.getAddress().getPort()),
                    "sb_publishable_test", "kiosk@example.invalid", "test-password");
            service.beginStudentSession("005", "S-001");
            service.logActivity("PC-1", "Edge", "msedge.exe", "BLOCKED");
            service.logActivity("PC-1", "Notepad", "notepad.exe", "OPENED");
            service.addUsageLog("005", "Notepad", "notepad.exe", "Test Student", "S-001");

            JsonNode batch = received.poll(10, TimeUnit.SECONDS);
            assertNotNull(batch);
            assertEquals(3, batch.size());
            JsonNode blocked = batch.get(0).path("fields");
            assertEquals("BLOCKED", blocked.path("action").asText());
            assertEquals("PC-1", blocked.path("pc_name").asText());
            assertEquals("005", blocked.path("class_code").asText());
            assertEquals("S-001", blocked.path("student_id").asText());
            assertTrue(blocked.path("timestamp").asLong() > 0);
            assertEquals(batch, received.poll(10, TimeUnit.SECONDS));
            assertEquals(batch, received.poll(10, TimeUnit.SECONDS));
            JsonNode opened = batch.get(1).path("fields");
            assertEquals("OPENED", opened.path("action").asText());
            assertFalse(blocked.path("id").equals(opened.path("id")));
            JsonNode usage = batch.get(2).path("fields");
            assertEquals("005", usage.path("class_code").asText());
            assertEquals("Opened Notepad", usage.path("student_log").asText());
            assertEquals("Test Student", usage.path("student_name").asText());
            assertEquals("S-001", usage.path("student_id").asText());
            assertEquals("Bearer test-token-1", tokens.poll());
            assertEquals("Bearer test-token-1", tokens.poll());
            assertEquals("Bearer test-token-2", tokens.poll());
            assertEquals(2, signIns.get());
        } finally {
            server.stop(0);
        }
    }
}
