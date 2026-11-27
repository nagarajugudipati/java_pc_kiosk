package com.labcontrol.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.io.Reader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.channels.FileChannel;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;

public final class SupabaseService {
    private static final Duration TIMEOUT = Duration.ofSeconds(5);
    private static final int MAX_ATTEMPTS = 3;
    private static final ObjectMapper JSON = new ObjectMapper();

    private static final class Shared {
        private static final SupabaseService INSTANCE = new SupabaseService(loadConfiguration());
    }

    private record Configuration(URI origin, String key, String email, String password, Path spool, String pcName) {}
    private record Event(String kind, Map<String, Object> fields) {}
    private record StudentSession(String classCode, String studentId) {}

    private final Configuration configuration;
    private final Thread writer;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
    private final ArrayBlockingQueue<Event> pending = new ArrayBlockingQueue<>(256);
    private volatile StudentSession studentSession;
    private volatile String token;
    private long tokenExpiresAt;

    private SupabaseService(Configuration configuration) {
        this.configuration = configuration;
        if (configuration != null) {
            writer = new Thread(this::writePending, "SupabaseLogWriter");
            writer.setDaemon(true);
            writer.start();
        } else {
            writer = null;
        }
    }

    // Package-private entry point for testing HTTP behavior against a local server.
    SupabaseService(URI origin, String key, String email, String password) {
        this(origin, key, email, password, null);
    }

    SupabaseService(URI origin, String key, String email, String password, Path spool) {
        this(new Configuration(origin, key, email, password, spool, ""));
    }

    public static SupabaseService shared() {
        return Shared.INSTANCE;
    }

    public String computerName() {
        if (configuration != null && !configuration.pcName().isBlank()) {
            return configuration.pcName();
        }
        return System.getenv().getOrDefault("COMPUTERNAME", "PC-1");
    }

    void stopWriter() throws InterruptedException {
        if (writer != null) {
            writer.interrupt();
            writer.join(6000);
        }
    }

    private static Configuration loadConfiguration() {
        try {
            Properties local = new Properties();
            String file = System.getenv("SUPABASE_CONFIG_FILE");
            String programData = System.getenv("ProgramData");
            if (file == null && programData != null) {
                Path defaultFile = Path.of(programData, "LabControlStudentAgent", "supabase.local.properties");
                if (Files.exists(defaultFile)) {
                    file = defaultFile.toString();
                }
            }
            if (file != null) {
                try (Reader reader = Files.newBufferedReader(Path.of(file))) {
                    local.load(reader);
                }
            }
            String url = setting(local, "SUPABASE_URL");
            String key = setting(local, "SUPABASE_PUBLISHABLE_KEY");
            String email = setting(local, "SUPABASE_KIOSK_EMAIL");
            String password = setting(local, "SUPABASE_KIOSK_PASSWORD");
            URI origin = URI.create(url);
            if (!"https".equalsIgnoreCase(origin.getScheme()) || origin.getHost() == null
                    || origin.getRawUserInfo() != null || origin.getRawQuery() != null
                    || origin.getRawFragment() != null
                    || !(origin.getPath().isEmpty() || "/".equals(origin.getPath()))
                    || !key.matches("sb_publishable_[A-Za-z0-9_-]+") || email.isBlank() || password.isBlank()) {
                throw new IllegalArgumentException();
            }
            String localAppData = System.getenv("LOCALAPPDATA");
            Path base = localAppData == null ? Path.of(System.getProperty("user.home"), ".kiosk")
                    : Path.of(localAppData, "LabControlStudentAgent");
            UUID scope = UUID.nameUUIDFromBytes((origin.getHost() + "|" + email).getBytes(StandardCharsets.UTF_8));
            return new Configuration(origin, key, email, password, base.resolve("pending").resolve(scope.toString()),
                    setting(local, "KIOSK_PC_NAME").strip());
        } catch (IOException | RuntimeException e) {
            System.err.println("Supabase logging disabled. Check the kiosk configuration.");
            return null;
        }
    }

    private static String setting(Properties local, String name) {
        return System.getenv().getOrDefault(name, local.getProperty(name, ""));
    }

    public void addUsageLog(String classCode, String appName, String processName, String studentName) {
        addUsageLog(classCode, appName, processName, studentName, null);
    }

    public void addUsageLog(String classCode, String appName, String processName, String studentName,
                            String studentId) {
        addClassUsage(classCode, appName, processName, studentName, studentId, null);
    }

    public void addClassUsage(String classCode, String appName, String processName, String studentName,
                              String studentId, String sessionId) {
        addClassUsage(classCode, appName, processName, studentName, studentId, sessionId,
                System.currentTimeMillis(), null);
    }

    public void addClassUsage(String classCode, String appName, String processName, String studentName,
                              String studentId, String sessionId, long startedAt, Long durationSeconds) {
        Map<String, String> fields = new HashMap<>(Map.of(
                "class_code", classCode, "app_name", appName, "process_name", processName,
                "student_log", "Opened " + appName, "student_name", studentName));
        if (studentId != null) {
            fields.put("student_id", studentId);
        }
        if (sessionId != null) fields.put("student_session_id", sessionId);
        if (durationSeconds != null) fields.put("usage_duration_seconds", durationSeconds.toString());
        enqueue("usage", fields, startedAt);
    }

    public void addUsageLog(String classCode, String processName, String studentName) {
        addUsageLog(classCode, processName, processName, studentName);
    }

    public void logActivity(String pcName, String appName, String processName, String action) {
        StudentSession current = studentSession;
        logClassActivity(pcName, appName, processName, action,
                current == null ? null : current.classCode(), current == null ? null : current.studentId(), null);
    }

    public void logClassActivity(String pcName, String appName, String processName, String action,
                                 String classCode, String studentId, String sessionId) {
        Map<String, String> fields = new HashMap<>(Map.of(
                "pc_name", pcName, "app_name", appName, "process_name", processName, "action", action));
        if (classCode != null) fields.put("class_code", classCode);
        if (studentId != null) fields.put("student_id", studentId);
        if (sessionId != null) fields.put("student_session_id", sessionId);
        enqueue("activity", fields);
    }

    public void beginStudentSession(String classCode, String studentId) {
        studentSession = new StudentSession(classCode, studentId);
    }

    public void endStudentSession() {
        studentSession = null;
    }

    private void enqueue(String kind, Map<String, String> fields) {
        enqueue(kind, fields, System.currentTimeMillis());
    }

    private void enqueue(String kind, Map<String, String> fields, long timestamp) {
        if (configuration == null) {
            return;
        }
        Map<String, Object> event = new HashMap<>(fields);
        event.put("id", UUID.randomUUID().toString());
        event.put("timestamp", timestamp);
        Event entry = new Event(kind, event);
        if (configuration.spool() != null) {
            savePending(entry);
        } else if (!pending.offer(entry)) {
            System.err.println("Supabase log queue full. Event dropped.");
        }
    }

    private synchronized void savePending(Event event) {
        Path folder = configuration.spool();
        try {
            Files.createDirectories(folder);
            try (var files = Files.list(folder)) {
                if (files.limit(4096).count() == 4096) {
                    System.err.println("Kiosk offline queue is full.");
                    return;
                }
            }
            String name = event.fields().get("timestamp") + "-" + event.fields().get("id");
            Path temp = Files.createTempFile(folder, name, ".tmp");
            try {
                ByteBuffer data = ByteBuffer.wrap(JSON.writeValueAsBytes(event));
                try (var file = FileChannel.open(temp, java.nio.file.StandardOpenOption.WRITE)) {
                    while (data.hasRemaining()) file.write(data);
                    file.force(true);
                }
                Files.move(temp, folder.resolve(name + ".json"), StandardCopyOption.ATOMIC_MOVE);
            } finally {
                Files.deleteIfExists(temp);
            }
        } catch (IOException e) {
            System.err.println("Could not save an event to the kiosk offline queue.");
        }
    }

    private void drainSpool() throws InterruptedException {
        Path folder = configuration.spool();
        if (!Files.isDirectory(folder)) return;
        try {
            List<Path> paths;
            try (var files = Files.list(folder)) {
                paths = files.filter(path -> path.toString().endsWith(".json")).sorted().limit(32).toList();
            }
            List<Event> events = new ArrayList<>();
            List<Path> valid = new ArrayList<>();
            for (Path path : paths) {
                try {
                    events.add(JSON.readValue(path.toFile(), Event.class));
                    valid.add(path);
                } catch (java.nio.file.NoSuchFileException | java.io.FileNotFoundException ignored) {
                    // Another running kiosk process acknowledged it.
                } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
                    Files.move(path, path.resolveSibling(path.getFileName() + ".rejected"), StandardCopyOption.REPLACE_EXISTING);
                }
            }
            if (events.isEmpty()) return;
            Delivery delivery = write(events);
            if (delivery == Delivery.ACCEPTED) {
                for (Path path : valid) Files.deleteIfExists(path);
            } else if (delivery == Delivery.REJECTED) {
                for (int i = 0; i < events.size(); i++) {
                    Path path = valid.get(i);
                    switch (write(List.of(events.get(i)))) {
                        case ACCEPTED -> Files.deleteIfExists(path);
                        case REJECTED -> {
                            if (Files.exists(path)) Files.move(path, path.resolveSibling(path.getFileName() + ".rejected"),
                                    StandardCopyOption.REPLACE_EXISTING);
                        }
                        case RETRY -> { return; }
                    }
                }
            }
        } catch (IOException e) {
            System.err.println("Could not read or acknowledge kiosk offline activity.");
        }
    }

    private void writePending() {
        try {
            while (!Thread.currentThread().isInterrupted()) {
                if (configuration.spool() != null) {
                    drainSpool();
                    Thread.sleep(1000);
                    continue;
                }
                List<Event> batch = new ArrayList<>(32);
                batch.add(pending.take());
                Thread.sleep(100);
                pending.drainTo(batch, 31);
                if (write(batch) == Delivery.REJECTED && batch.size() > 1) {
                    for (Event event : batch) write(List.of(event));
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private enum Delivery { ACCEPTED, REJECTED, RETRY }

    private Delivery write(List<Event> batch) {
        for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            try {
                authenticate();
                HttpResponse<String> response = post("/rest/v1/rpc/record_kiosk_events",
                        Map.of("p_events", batch), token);
                int status = response.statusCode();
                if (status >= 200 && status < 300) {
                    return Delivery.ACCEPTED;
                }
                if (status == 401) {
                    token = null;
                }
                if (attempt == MAX_ATTEMPTS || (status != 401 && !isTemporary(status))) {
                    System.err.println("Supabase log write failed (HTTP " + status + ").");
                    return status == 400 || status == 403 || status == 422 ? Delivery.REJECTED : Delivery.RETRY;
                }
            } catch (AuthenticationException e) {
                if (attempt == MAX_ATTEMPTS || !isTemporary(e.status)) {
                    System.err.println("Supabase kiosk sign-in failed (HTTP " + e.status + ").");
                    return Delivery.RETRY;
                }
            } catch (IOException e) {
                if (attempt == MAX_ATTEMPTS) {
                    System.err.println("Supabase request failed. Retry pending.");
                    return Delivery.RETRY;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return Delivery.RETRY;
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return Delivery.RETRY;
            }
        }
        return Delivery.RETRY;
    }

    private static boolean isTemporary(int status) {
        return status == 408 || status == 429 || status >= 500;
    }

    private synchronized void authenticate() throws IOException, InterruptedException {
        if (token != null && System.currentTimeMillis() < tokenExpiresAt) {
            return;
        }
        HttpResponse<String> response = post("/auth/v1/token?grant_type=password",
                Map.of("email", configuration.email(), "password", configuration.password()), null);
        if (response.statusCode() != 200) {
            throw new AuthenticationException(response.statusCode());
        }
        JsonNode body = JSON.readTree(response.body());
        if (body == null) {
            throw new IOException("Empty sign-in response");
        }
        String accessToken = body.path("access_token").asText();
        long seconds = body.path("expires_in").asLong();
        if (!accessToken.matches("[A-Za-z0-9_.-]+") || seconds <= 0) {
            throw new IOException("Invalid sign-in response");
        }
        token = accessToken;
        tokenExpiresAt = System.currentTimeMillis() + Math.max(0, seconds - 30) * 1000;
    }

    public JsonNode control(String operation, Map<String, ?> values) throws IOException, InterruptedException {
        if (configuration == null) throw new IOException("Supabase kiosk configuration is unavailable.");
        for (int attempt = 0; attempt < 2; attempt++) {
            authenticate();
            String accessToken = token;
            HttpResponse<String> response = post("/rest/v1/rpc/" + operation, values, accessToken);
            if (response.statusCode() >= 200 && response.statusCode() < 300) {
                return response.body().isBlank() ? JSON.nullNode() : JSON.readTree(response.body());
            }
            if (response.statusCode() != 401 || attempt == 1) {
                throw new IOException("Class service returned HTTP " + response.statusCode());
            }
            token = null;
        }
        throw new IOException("Class service rejected kiosk authentication.");
    }

    private HttpResponse<String> post(String path, Map<String, ?> body, String accessToken)
            throws IOException, InterruptedException {
        HttpRequest.Builder request = HttpRequest.newBuilder(configuration.origin().resolve(path))
                .timeout(TIMEOUT)
                .header("apikey", configuration.key())
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(JSON.writeValueAsString(body)));
        if (accessToken != null) {
            request.header("Authorization", "Bearer " + accessToken);
            request.header("Prefer", "return=minimal");
        }
        return http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }

    private static final class AuthenticationException extends IOException {
        private final int status;

        private AuthenticationException(int status) {
            this.status = status;
        }
    }
}
