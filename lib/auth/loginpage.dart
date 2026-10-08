// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';
import 'package:parking/home/screens/root_app.dart';
import 'package:parking/services/ird_bill.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController emailController = TextEditingController();

  bool isLoading = false;
  bool obscurePassword = true;
  bool hasBaseUrl = false; // Track if baseUrl exists

  static const String resolverUrl =
      "https://wheelstrulyyours.com.np/api/tenant/central-resolver/";

  @override
  void initState() {
    super.initState();
    _checkBaseUrl();
  }

  /// Check if baseUrl already exists
  Future<void> _checkBaseUrl() async {
    final savedBaseUrl = await SecureStorage.getBaseUrl();
    setState(() {
      hasBaseUrl = savedBaseUrl != null && savedBaseUrl.isNotEmpty;
    });
    if (hasBaseUrl) {
      print("BaseUrl already exists: ${ApiEndpoints.baseUrl}");
    }
  }

  Future<String?> _resolveTenant(String email) async {
    try {
      final response = await http.post(
        Uri.parse(resolverUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"email": email.trim()}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String baseUrl = data['base_url'] as String;

        final cleanedUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
        print(cleanedUrl);
        ApiEndpoints.baseUrl = "$cleanedUrl/api/";
        await SecureStorage.saveBaseUrl("$cleanedUrl/api/");

        return cleanedUrl;
      } else {
        print("Resolver error: ${response.statusCode} - ${response.body}");
        return null;
      }
    } catch (e) {
      print("Resolver exception: $e");
      return null;
    }
  }

  /// The server address typed in by hand. The usual way, the email lookup, asks our cloud
  /// where this mall's server is -- which needs internet. A mall that runs on its own PC can
  /// still log a POS in while its internet is down by typing the PC's address here.
  Future<void> _setServerAddress() async {
    final controller = TextEditingController(
      text: ApiEndpoints.baseUrl.replaceFirst(RegExp(r'/api/?$'), ''),
    );
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'http://192.168.1.50'),
        ),
        actions: [
          // Empty: go back to finding the server from the email
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Use email'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (entered == null) return;

    var url = entered.trim();
    if (url.isEmpty) {
      ApiEndpoints.baseUrl = '';
      await SecureStorage.saveBaseUrl('');
      setState(() => hasBaseUrl = false);
      return;
    }
    if (!url.startsWith(RegExp(r'https?://'))) url = 'http://$url';
    url = url.replaceFirst(RegExp(r'/+$'), '');
    ApiEndpoints.baseUrl = '$url/api/';
    await SecureStorage.saveBaseUrl('$url/api/');
    setState(() => hasBaseUrl = true);
  }

  Future<void> _performLogin() async {
    try {
      final response = await http.post(
        Uri.parse("${ApiEndpoints.baseUrl}authentication/users/pos-login/"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": usernameController.text.trim(),
          "password": passwordController.text.trim(),
        }),
      );

      print("Login response: ${response.statusCode}");
      print(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);

        await SecureStorage.saveLoginData(
          id: data['id'].toString(),
          accessToken: data['access'],
          refreshToken: data['refresh'],
          fullName: data['full_name'],
          role: data['role'],
          freeTime: data['free_time'],
        );
        await IrdBill.rememberFromLogin(data);

        if (data['parking_slip_details'] != null) {
          final parkingSlipDetails = data['parking_slip_details'];
          await SecureStorage.saveParkingSlipDetails(
            heading1: parkingSlipDetails['heading1'] ?? '',
            heading2: parkingSlipDetails['heading2'] ?? '',
            heading3: parkingSlipDetails['heading3'] ?? '',
            heading4: parkingSlipDetails['heading4'] ?? '',
            footerText: parkingSlipDetails['footer_text'] ?? '',
          );
        }
        if (data['parking_rates'] != null) {
          await SecureStorage.saveParkingRates(data['parking_rates']);
          if (!mounted) return;

          await _prewarmImageCache(data['parking_rates'], context);
        }

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => const AppShell(),
            transitionsBuilder: (_, __, ___, child) => child,
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Invalid credentials"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      print("LOGIN ERROR: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Login failed. Please try again."),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // In your auth service / login handler, after saving rates:
  Future<void> _prewarmImageCache(
    List<dynamic> parkingRates,
    BuildContext context,
  ) async {
    for (final rate in parkingRates) {
      final iconUrl = rate['icon'] as String?;
      if (iconUrl != null && iconUrl.isNotEmpty) {
        await precacheImage(CachedNetworkImageProvider(iconUrl), context);
      }
    }
  }

  /// Main login button action
  Future<void> login() async {
    // If baseUrl doesn't exist, we need email for tenant resolution
    if (!hasBaseUrl) {
      if (emailController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please enter your email")),
        );
        return;
      }
    }

    setState(() {
      isLoading = true;
    });

    // Step 1: Resolve tenant only if baseUrl doesn't exist
    if (!hasBaseUrl) {
      final resolvedUrl = await _resolveTenant(emailController.text.trim());

      if (resolvedUrl == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Unable to find tenant for this email. Contact admin.",
            ),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          isLoading = false;
        });
        return;
      }

      // Update state to hide email field for next time
      setState(() {
        hasBaseUrl = true;
      });
    }

    // Step 2: Perform login
    await _performLogin();

    setState(() {
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF6F93AF),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                Image.asset("assets/goodwish.png", height: 60),
                const SizedBox(height: 20),
                const Text(
                  "Sign In",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Log in to manage your parking operations.",
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 40),

                // Email Field - Only show if baseUrl doesn't exist
                if (!hasBaseUrl) ...[
                  const Text("Email", style: TextStyle(color: Colors.white)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Username/Phone Field
                const Text(
                  "Username or phone",
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: usernameController,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Password Field
                const Text("Password", style: TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() => obscurePassword = !obscurePassword);
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),

                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  height: 70,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0B4EDB),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            "Log In",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: isLoading ? null : _setServerAddress,
                    child: const Text(
                      "Server address",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
