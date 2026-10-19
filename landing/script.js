// This static site has no usage reporting or network script.
// Decorative recording timer. It stays still when reduced motion is enabled.
(function () {
    var el = document.getElementById('rec-time');
    if (!el || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    var seconds = 0;
    setInterval(function () {
        seconds += 1;
        var minutes = Math.floor(seconds / 60), remainder = seconds % 60;
        el.textContent = (minutes < 10 ? '0' + minutes : minutes)
            + ':' + (remainder < 10 ? '0' + remainder : remainder);
    }, 1000);
})();
