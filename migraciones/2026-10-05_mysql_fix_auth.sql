USE CR_Chat;
-- Corrige: login con cualquier contraseña, filtros de contactos y alias del texto en mensajes
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_authorized_user$$
CREATE PROCEDURE sp_authorized_user(
  IN p_phone_number VARCHAR(255),
  IN p_pass VARCHAR(255),
  IN p_key VARCHAR(255)
)
BEGIN
   DECLARE v_id_user INT;
  DECLARE bin_pass VARBINARY(64);
  DECLARE bin_email VARBINARY(64);

  SET bin_pass = AES_ENCRYPT(p_pass, p_key);
  SET bin_email = AES_ENCRYPT(p_phone_number, p_key);

  -- Convertimos la contraseÃ±a a VARBINARY para comparar con la almacenada
  SELECT id_user INTO v_id_user
  FROM usr
  WHERE (phone_number = p_phone_number OR email = bin_email)
    AND pass = bin_pass
    AND deleted = FALSE
  LIMIT 1;

  -- Si no se encontrÃ³ el usuario, se retorna -1
  IF v_id_user IS NULL THEN
    SET v_id_user = -1;
  END IF;

  SELECT v_id_user AS id_user;
END $$

DROP PROCEDURE IF EXISTS sp_load_contact$$
CREATE PROCEDURE sp_load_contact(
    IN p_lim INT,
    IN p_pag INT,
    IN p_phone_contact VARCHAR(20),
    IN p_contact_name VARCHAR(100),
    IN p_id_user INT 
)
BEGIN    
        SELECT id_contact, id_user, contact_number, contact_name
        FROM contact
        WHERE deleted = FALSE AND id_user = p_id_user
          AND (p_phone_contact IS NULL OR contact_number LIKE CONCAT('%', p_phone_contact, '%'))
          AND (p_contact_name IS NULL OR contact_name LIKE CONCAT('%', p_contact_name, '%'))
        LIMIT p_pag, p_lim;    
END $$

DROP PROCEDURE IF EXISTS sp_load_message$$
CREATE PROCEDURE sp_load_message(
    IN p_id_chat INT,
    IN p_key VARCHAR(50)
)
BEGIN
    SELECT id_message, id_chat_sender, id_chat_receiver, shipping_date, delivery_date, media_content, CAST(aes_decrypt(text_message, p_key) AS CHAR) AS text_message, deleted, delivered, seen
    FROM message_chat
    WHERE (id_chat_sender = p_id_chat OR id_chat_receiver = p_id_chat)
      AND deleted = FALSE
    ORDER BY shipping_date ASC
    LIMIT 15;
END $$

DELIMITER ;
