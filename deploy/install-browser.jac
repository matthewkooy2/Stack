# Image build tooling: install Chromium through the dependency loaded by Jac.
import sys;
import from playwright.__main__ { main }
with entry {
    sys.argv = ["playwright", "install", "--with-deps", "--only-shell", "chromium"];
    main();
}
