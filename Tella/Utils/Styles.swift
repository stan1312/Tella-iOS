//
//  Copyright © 2021 HORIZONTAL. 
//  Licensed under MIT (https://github.com/Horizontal-org/Tella-iOS/blob/develop/LICENSE)
//


import UIKit
import SwiftUI

struct Styles {
    
    struct uiColor {
        static let backgroundMain = UIColor(hexValue: 0x000000)   // SPECTRE: black & white
        static let backgroundTab = UIColor(hexValue: 0x111111)
        static let yellow = UIColor(hexValue: 0xFFFFFF)   // accent: white
        static let lightBlue = UIColor(hexValue: 0xBDBDBD)
        static let disabledYellow = UIColor(hexValue: 0x333333)
        static let gray = UIColor(hexValue: 0xDCDCDC)
        static let backgroundToast = UIColor(hexValue: 0xE8E8EC)
    }
    
    struct Colors {
        static let backgroundMain = Color(uiColor.backgroundMain)
        static let backgroundTab = Color(uiColor.backgroundTab)
        static let yellow = Color(uiColor.yellow)
        static let lightBlue = Color(uiColor.lightBlue)
        static let disabledYellow = Color(uiColor.disabledYellow)
        static let gray = Color(uiColor.gray)
        static let backgroundToast = Color(uiColor.backgroundToast)
    }
    
    struct Stroke {
        static let buttonAdd = StrokeStyle(
            lineWidth: 1,
            lineCap: .round,
            lineJoin: .miter,
            miterLimit: 0,
            dash: [8, 2],
            dashPhase: 0
        )
    }
    
    struct Fonts {
        static var boldFontName = "HelveticaNeue-Bold"
        static var regularFontName = "HelveticaNeue"
        static var semiBoldFontName = "HelveticaNeue-Medium"
        static var lightFontName = "HelveticaNeue-Light"
        static var lightRobotoFontName = "HelveticaNeue-Light"
        static var italicRobotoFontName = "HelveticaNeue-Italic"
    }
}

public extension UIColor {
    
    convenience init(redInt: Int, greenInt: Int, blueInt: Int, alpha: CGFloat=1.0) {
        self.init(red: CGFloat(redInt)/255.0, green: CGFloat(greenInt)/255.0, blue: CGFloat(blueInt)/255.0, alpha: alpha)
    }
    
    convenience init(hexValue: Int) {
        let red = (hexValue >> 16) & 0xFF
        let green = (hexValue >> 8) & 0xFF
        let blue = hexValue & 0xFF
        
        self.init(redInt: red, greenInt: green, blueInt: blue)
    }
}

var safeArea: UIEdgeInsets {
    return UIApplication.shared.windows.last?.safeAreaInsets ?? .zero
}

