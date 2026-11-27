package com.labcontrol.cli;

import com.labcontrol.engine.ManagedClass;

import javax.swing.*;
import java.awt.*;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.awt.image.BufferedImage;
import java.io.IOException;

public final class StudentKioskWindow {
    private final ManagedClass kiosk = new ManagedClass();
    private final JFrame window = new JFrame("Lab Control Student Kiosk");
    private final JLabel status = new JLabel("No active class");
    private final JTextField code = new JTextField(20);
    private final JTextField roll = new JTextField(20);
    private final JTextField name = new JTextField(20);
    private final JButton join = new JButton("Join class");

    public void show() {
        JPanel form = new JPanel(new GridLayout(0, 2, 8, 8));
        form.setBorder(BorderFactory.createEmptyBorder(16, 16, 16, 16));
        form.add(new JLabel("Class code"));
        form.add(code);
        form.add(new JLabel("Roll number"));
        form.add(roll);
        form.add(new JLabel("Student name"));
        form.add(name);
        form.add(join);
        form.add(status);
        window.add(form);
        window.setDefaultCloseOperation(WindowConstants.DO_NOTHING_ON_CLOSE);
        window.addWindowListener(new WindowAdapter() {
            @Override
            public void windowClosing(WindowEvent event) {
                if (tray != null) {
                    window.setVisible(false);
                } else {
                    window.setState(Frame.ICONIFIED);
                }
            }
        });
        join.addActionListener(event -> joinClass());
        installTray();
        new Timer(1000, event -> {
            String current = kiosk.sessionStatus();
            if (!current.equals(lastStatus)) {
                lastStatus = current;
                status.setText(current);
                join.setEnabled(current.equals("No active class"));
                if (tray != null) tray.setToolTip("Lab Control - " + current);
            }
        }).start();
        window.pack();
        window.setSize(630, window.getHeight());
        window.setLocationRelativeTo(null);
        window.setVisible(true);
    }

    private TrayIcon tray;
    private String lastStatus = "No active class";

    private void installTray() {
        if (!SystemTray.isSupported()) return;
        BufferedImage icon = new BufferedImage(24, 24, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = icon.createGraphics();
        graphics.setColor(new Color(21, 91, 82));
        graphics.fillRoundRect(0, 0, 24, 24, 6, 6);
        graphics.setColor(Color.WHITE);
        graphics.drawString("LC", 4, 16);
        graphics.dispose();
        TrayIcon candidate = new TrayIcon(icon, "Lab Control - No active class");
        candidate.setImageAutoSize(true);
        candidate.addActionListener(event -> SwingUtilities.invokeLater(() -> {
            window.setVisible(true);
            window.setState(Frame.NORMAL);
            window.toFront();
        }));
        try {
            SystemTray.getSystemTray().add(candidate);
            tray = candidate;
        } catch (AWTException ignored) {
            // The taskbar remains available if Windows cannot show a tray icon.
        }
    }

    private void joinClass() {
        String classCode = code.getText().strip();
        String rollNumber = roll.getText().strip();
        String studentName = name.getText().strip();
        if (classCode.isEmpty() || rollNumber.isEmpty() || studentName.isEmpty()) {
            status.setText("Enter all three fields.");
            return;
        }
        join.setEnabled(false);
        status.setText("Joining class...");
        Thread worker = new Thread(() -> {
            String result;
            try {
                kiosk.join(classCode, rollNumber, studentName);
                result = kiosk.sessionStatus();
            } catch (IOException e) {
                result = e.getMessage();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                result = "Class join interrupted.";
            }
            String message = result;
            SwingUtilities.invokeLater(() -> {
                status.setText(message);
                join.setEnabled(kiosk.sessionStatus().equals("No active class"));
            });
        }, "StudentClassJoin");
        worker.setDaemon(true);
        worker.start();
    }
}
