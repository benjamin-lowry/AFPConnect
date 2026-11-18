//
//  AFPFS.swift
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-05.
//
//  Exports the AFPFSFileSystem to FSKit. UnaryFileSystemExtension is a Swift protocol so we can't do this from objc

import ExtensionFoundation
import Foundation
import FSKit

@main
struct AFPFS : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        AFPFSFileSystem()
    }
}
