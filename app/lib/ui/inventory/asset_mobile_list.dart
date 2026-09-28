import 'package:flutter/material.dart';

import '../../models/inventory.dart';

/// Android rows show only the serial number and item name.
class AssetMobileList extends StatelessWidget {
  const AssetMobileList({
    super.key,
    required this.assets,
    required this.onTap,
  });

  final List<Asset> assets;
  final ValueChanged<Asset> onTap;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: EdgeInsets.zero,
    itemCount: assets.length,
    separatorBuilder: (_, _) => const Divider(height: 1),
    itemBuilder: (context, index) {
      final asset = assets[index];
      final serial = asset.serialNo?.trim();
      return ListTile(
        key: ValueKey(asset.id),
        title: Text(
          serial == null || serial.isEmpty ? asset.assetNo : serial,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(asset.name),
        onTap: () => onTap(asset),
      );
    },
  );
}
