package com.labcontrol.engine;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.function.Consumer;
import java.util.function.Supplier;

final class BrowserBridge implements AutoCloseable {
    private static final ObjectMapper JSON = new ObjectMapper();
    private final HttpServer server;

    BrowserBridge(String token, Supplier<?> policy, Consumer<JsonNode> event) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 48731), 8);
        server.createContext("/kiosk/", exchange -> {
            try (exchange) {
                String auth = exchange.getRequestHeaders().getFirst("Authorization");
                if (auth == null || !MessageDigest.isEqual(auth.getBytes(StandardCharsets.UTF_8),
                        ("Bearer " + token).getBytes(StandardCharsets.UTF_8))) {
                    exchange.sendResponseHeaders(401, -1);
                    return;
                }
                String path = exchange.getRequestURI().getPath();
                if (path.equals("/kiosk/policy") && exchange.getRequestMethod().equals("GET")) {
                    byte[] body = JSON.writeValueAsBytes(policy.get());
                    exchange.getResponseHeaders().set("Content-Type", "application/json");
                    exchange.getResponseHeaders().set("Cache-Control", "no-store");
                    exchange.sendResponseHeaders(200, body.length);
                    exchange.getResponseBody().write(body);
                } else if (path.equals("/kiosk/event") && exchange.getRequestMethod().equals("POST")) {
                    byte[] body = exchange.getRequestBody().readNBytes(2049);
                    if (body.length > 2048) {
                        exchange.sendResponseHeaders(413, -1);
                        return;
                    }
                    JsonNode input;
                    try { input = JSON.readTree(body); }
                    catch (IOException e) {
                        exchange.sendResponseHeaders(400, -1);
                        return;
                    }
                    if (input != null && input.isObject()) event.accept(input);
                    exchange.sendResponseHeaders(204, -1);
                } else {
                    exchange.sendResponseHeaders(404, -1);
                }
            }
        });
        server.start();
    }

    @Override
    public void close() {
        server.stop(0);
    }
}
