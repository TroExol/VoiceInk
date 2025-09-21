import Foundation
import ObjectiveC.runtime

private var associatedBundleKey: UInt8 = 0

private final class LocalizedBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &associatedBundleKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

private let swizzleLocalizationBundle: Void = {
    object_setClass(Bundle.main, LocalizedBundle.self)
}()

extension Bundle {
    static func setLanguage(_ languageCode: String) {
        _ = swizzleLocalizationBundle

        guard
            let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            objc_setAssociatedObject(Bundle.main, &associatedBundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        objc_setAssociatedObject(Bundle.main, &associatedBundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
