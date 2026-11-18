<?php

namespace App\Support;

// Política de contraseñas (A-02): 10..128 caracteres, distinta de email/teléfono y no común.
final class Password
{
    private const COMMON = [
        '1234567890', '12345678910', '0123456789', '1111111111', '0000000000', '1234512345',
        'qwertyuiop', 'asdfghjkl1', 'password12', 'password123', 'password1234', 'passw0rd123',
        'contrasena', 'contraseña', 'contrasena1', 'contraseña1', 'contrasena123', 'contraseña123',
        'iloveyou12', 'qwerty1234', 'qwerty12345', '1q2w3e4r5t', '1qaz2wsx3edc', 'abcdefghij',
        'abc1234567', 'abcd123456', 'admin12345', 'administrador', 'bienvenido', 'bienvenido1',
        'micontrasena', 'holamundo1', 'superman123', 'princesa123', 'football123', 'baseball123',
        'dragon1234', 'monkey1234', 'letmein123', 'sunshine12', 'welcome123', 'trustno1234',
        'changeme123', 'cambiar123', 'cambiame123', 'costarica1', 'costarica123', 'teamo12345',
    ];

    /** @return string|null mensaje de error o null si es válida */
    public static function violation(string $password, ?string $email = null, ?string $phone = null): ?string
    {
        $len = mb_strlen($password, 'UTF-8');
        if ($len < 10 || $len > 128) {
            return 'Debe tener entre 10 y 128 caracteres.';
        }
        $lower = mb_strtolower($password, 'UTF-8');
        if (in_array($lower, self::COMMON, true) || count(array_unique(mb_str_split($lower))) <= 2) {
            return 'Es una contraseña demasiado común.';
        }
        if ($email !== null && ($lower === mb_strtolower($email) || $lower === mb_strtolower(strstr($email, '@', true) ?: ''))) {
            return 'No puede coincidir con el email.';
        }
        if ($phone !== null && (ltrim($password, '+') === ltrim($phone, '+'))) {
            return 'No puede coincidir con el teléfono.';
        }
        return null;
    }
}
