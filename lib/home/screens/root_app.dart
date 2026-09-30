import 'package:flutter/material.dart';
import 'package:parking/drawer/drawer.dart';
import 'package:parking/drawer/searchvehicle.dart';
import 'package:parking/home/screens/homepage.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int selectedIndex = 0;

  // Members are added, renewed and listed on the website now, and the gate panel
  // holds the cards it needs. The POS keeps the jobs that have to work at the
  // counter with the till: parking, and finding a lost slip.
  final List<Widget> screens = const [
    Homepage(),
    SearchLostVehicleScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (selectedIndex != 0) {
          setState(() => selectedIndex = 0);
          return false;
        }
        return true;
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: const Color(0xFF668DAF),
        endDrawer: Mydrawer(
          selectedIndex: selectedIndex,
          onSelect: (index) {
            setState(() => selectedIndex = index);
          },
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _AppHeader(
                onMenuTap: () => _scaffoldKey.currentState?.openEndDrawer(),
                onSearchTap: () => setState(() => selectedIndex = 1),
              ),
              Expanded(child: screens[selectedIndex]),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  final VoidCallback onMenuTap;
  final VoidCallback onSearchTap;

  const _AppHeader({required this.onMenuTap, required this.onSearchTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(color: Color(0xFF090044)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Image.asset("assets/goodwish.png", height: 40),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.search, color: Colors.white),
                tooltip: 'Search vehicle',
                onPressed: onSearchTap,
              ),
              const SizedBox(width: 4),
              CircleAvatar(
                radius: 19,
                backgroundColor: Colors.white,
                child: IconButton(
                  icon: const Icon(Icons.menu, color: Colors.black),
                  onPressed: onMenuTap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
